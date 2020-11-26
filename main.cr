require "http"
require "ecr"

require "cache"
require "halite"
require "athena"
require "jwt"
require "sqlite3"

require "./util"

GITHUB_APP_NAME      = ENV["GITHUB_APP_NAME"]
GITHUB_APP_ID        = ENV["GITHUB_APP_ID"].to_i
GITHUB_CLIENT_ID     = ENV["GITHUB_OAUTH_CLIENT_ID"]
GITHUB_CLIENT_SECRET = ENV["GITHUB_OAUTH_CLIENT_SECRET"]
GITHUB_PEM_FILENAME  = ENV["GITHUB_PEM_FILENAME"]

alias InstallationId = Int64

struct AppToken
  def initialize(@token : String)
  end

  def to_s
    "Bearer #{@token}"
  end
end

struct UserToken
  def initialize(@token : String)
  end

  def to_s
    "token #{@token}"
  end
end

struct InstallationToken
  include JSON::Serializable
  getter token : String

  def initialize(@token : String)
  end

  def to_s
    "token #{@token}"
  end
end

class AppAuth
  def initialize(@app_id : Int32, @pem_filename : String)
  end

  def jwt : AppToken
    AppToken.new(@@jwt.fetch("#{@app_id}") do
      JWT.encode({
        iat: Time.utc.to_unix,                # issued at time
        exp: (Time.utc + 10.minutes).to_unix, # JWT expiration time (10 minute maximum)
        iss: @app_id,                         # GitHub App's identifier
      }, File.read(@pem_filename), JWT::Algorithm::RS256)
    end)
  end

  private def new_token(installation_id : InstallationId) : InstallationToken
    result = nil
    Client.post(
      "/app/installations/#{installation_id}/access_tokens",
      json: {permissions: {actions: "read"}},
      headers: {authorization: jwt}
    ) do |resp|
      resp.raise_for_status
      result = InstallationToken.from_json(resp.body_io)
    end
    result.not_nil!
  end

  def token(installation_id : InstallationId, *, new : Bool = false) : InstallationToken
    if new
      tok = new_token(installation_id)
      @@token.write("#{installation_id}", tok.token)
      tok
    else
      InstallationToken.new(@@token.fetch("#{installation_id}") do
        new_token(installation_id).token
      end)
    end
  end

  @@jwt = Cache::MemoryStore(String, String).new(expires_in: 9.minutes, compress: false)
  @@token = Cache::MemoryStore(String, String).new(expires_in: 9.minutes, compress: false)
end

AppClient = AppAuth.new(
  app_id: GITHUB_APP_ID,
  pem_filename: GITHUB_PEM_FILENAME,
)

Client = Halite::Client.new do
  endpoint("https://api.github.com/")
  logging(skip_request_body: true)
end

macro get_json_list(t, url, params = NamedTuple.new, max_items = 1000, **kwargs)
  %url : String? = {{url}}
  %max_items : Int32 = {{max_items}}
  %params = {per_page: %max_items}.merge({{params}})
  n = 0
  while %url
    result = nil
    Client.get(%url, params: %params, {{**kwargs}}) do |resp|
      resp.raise_for_status
      result = {{t}}.from_json(resp.body_io)
      %url = resp.links.try(&.["next"]?).try(&.target)
      %params = nil
    end
    result.not_nil!{% if t.is_a?(Path) %}.{{t.id.underscore}}{% end %}.each do |x|
      yield x
      n += 1
    end
    break if n > %max_items
  end
end

struct Installations
  include JSON::Serializable
  property installations : Array(Installation)

  def self.for_user(token : UserToken, & : Installation ->)
    # https://docs.github.com/v3/apps#list-app-installations-accessible-to-the-user-access-token
    get_json_list(
      Installations, "user/installations",
      headers: {authorization: token}, max_items: 10
    )
  end

  def self.for_app(token : AppToken, & : Installation ->)
    # https://docs.github.com/v3/apps#list-installations-for-the-authenticated-app
    get_json_list(
      Array(Installation), "app/installations",
      headers: {authorization: token}, max_items: 100000
    )
  end
end

spawn do
  Installations.for_app(AppClient.jwt) do |inst|
    RepoInstallations.write(inst.account.login, inst.id)
  end
end

struct Installation
  include JSON::Serializable
  property id : InstallationId
  property account : Account
end

struct Account
  include JSON::Serializable
  property login : String

  def self.for_oauth(token : OAuthToken) : Account
    # https://docs.github.com/v3/users#get-the-authenticated-user
    result = nil
    Client.get("user", headers: {authorization: token}) do |resp|
      resp.raise_for_status
      result = Account.from_json(resp.body_io)
    end
    result.not_nil!
  end
end

struct Repositories
  include JSON::Serializable
  property repositories : Array(Repository)

  def self.for_installation(installation_id : InstallationId, token : UserToken, & : Repository ->)
    # https://docs.github.com/v3/apps#list-repositories-accessible-to-the-user-access-token
    get_json_list(
      Repositories, "user/installations/#{installation_id}/repositories",
      headers: {authorization: token}, max_items: 300
    )
  end

  def self.for_installation(token : InstallationToken, & : Repository ->)
    # https://docs.github.com/v3/apps#list-repositories-accessible-to-the-app-installation
    get_json_list(
      Repositories, "installation/repositories",
      headers: {authorization: token}, max_items: 300
    )
  end
end

struct Repository
  include JSON::Serializable
  property full_name : String
  property private : Bool
  property fork : Bool
end

struct WorkflowRuns
  include JSON::Serializable
  property workflow_runs : Array(WorkflowRun)

  def self.for_workflow(repo_owner : String, repo_name : String, workflow : String, branch : String, token : InstallationToken | UserToken, max_items : Int32, & : WorkflowRun ->)
    get_json_list(
      WorkflowRuns, "repos/#{repo_owner}/#{repo_name}/actions/workflows/#{workflow}/runs",
      params: {branch: branch, event: "push", status: "success"},
      headers: {authorization: token}, max_items: max_items
    )
  end
end

struct WorkflowRun
  include JSON::Serializable
  property id : Int64
  property check_suite_url : String
end

struct Artifacts
  include JSON::Serializable
  property artifacts : Array(Artifact)

  def self.for_run(repo_owner : String, repo_name : String, run_id : Int64, token : InstallationToken | UserToken, & : Artifact ->)
    get_json_list(
      Artifacts, "repos/#{repo_owner}/#{repo_name}/actions/runs/#{run_id}/artifacts",
      headers: {authorization: token}, max_items: 100
    )
  end
end

struct Artifact
  include JSON::Serializable
  property id : Int64
  property name : String

  def self.zip_by_id(repo_owner : String, repo_name : String, artifact_id : Int64, token : InstallationToken | UserToken) : String
    Client.get(
      "repos/#{repo_owner}/#{repo_name}/actions/artifacts/#{artifact_id}/zip",
      headers: {authorization: token}
    ).tap(&.raise_for_status).headers["location"]
  end
end

D = DB.open("sqlite3:./db.sqlite")
D.exec(%(
  CREATE TABLE IF NOT EXISTS installations (
    repo_owner TEXT NOT NULL, installation_id INTEGER NOT NULL,
    UNIQUE(repo_owner)
  )
))

module RepoInstallations
  @@cache = Cache::MemoryStore(String, InstallationId).new(expires_in: 1.day, compress: false)

  def self.write(repo_owner : String, installation_id : InstallationId) : Nil
    D.exec(%(
      REPLACE INTO installations (repo_owner, installation_id) VALUES(?, ?)
    ), repo_owner, installation_id)
    @@cache.write("#{repo_owner}", installation_id)
  end

  def self.read(repo_owner : String) : InstallationId?
    @@cache.fetch("#{repo_owner}") do
      D.query_one(%(
        SELECT installation_id FROM installations WHERE repo_owner = ? LIMIT 1
      ), repo_owner, &.read(InstallationId))
    end
  end

  def self.delete(repo_owner : String) : Nil
    D.exec(%(
      DELETE FROM installations WHERE repo_owner = ?
    ), repo_owner)
    @@cache.delete("#{repo_owner}")
  end
end

struct OAuthToken
  def initialize(@token : String)
  end

  def to_s
    "token #{@token}"
  end
end

class AuthController < ART::Controller
  RECONFIGURE_URL = "https://github.com/apps/#{GITHUB_APP_NAME}/installations/new"

  @[ART::QueryParam("code")]
  @[ART::Get("/auth")]
  def do_auth(code : String? = nil) : ART::Response
    if !code
      return ART::RedirectResponse.new("https://github.com/login/oauth/authorize?" + HTTP::Params.encode({
        client_id: GITHUB_CLIENT_ID, scope: "",
      }))
    end

    resp = Client.post("https://github.com/login/oauth/access_token", form: {
      "client_id"     => GITHUB_CLIENT_ID,
      "client_secret" => GITHUB_CLIENT_SECRET,
      "code"          => code,
    }).tap(&.raise_for_status)
    resp = HTTP::Params.parse(resp.body)
    begin
      oauth_token = OAuthToken.new(resp["access_token"])
    rescue e
      if resp["error"]? == "bad_verification_code"
        return ART::RedirectResponse.new("/auth")
      end
      raise e
    end

    repo_owner = Account.for_oauth(oauth_token).login
    repos = [] of {Repository, String}

    # If the selection changes, the token becomes outdated, so get a new one.
    token = AppClient.token(RepoInstallations.read(repo_owner), new: true)
    Repositories.for_installation(token: token) do |repo|
      repos << {repo, "/" + repo.full_name}
    end

    ART::Response.new(headers: HTML_HEADERS) do |io|
      ECR.embed("head.html", io)
      ECR.embed("dashboard.html", io)
    end
  end
end

class ArtifactsController < ART::Controller
  record Link, url : String, title : String? = nil, ext : Bool = false

  struct Result
    property links = Array(Link).new
    property title : String = ""
  end

  @[ART::Get("/:repo_owner/:repo_name/artifact/:artifact_id")]
  def by_artifact(repo_owner : String, repo_name : String, artifact_id : Int64, check_suite_id : Int64? = nil) : ArtifactsController::Result
    token = AppClient.token(RepoInstallations.read(repo_owner))
    tmp_link = Artifact.zip_by_id(repo_owner, repo_name, artifact_id, token: token)
    result = Result.new
    result.title = "Repository #{repo_owner}/#{repo_name} | Artifact ##{artifact_id}"
    result.links << Link.new(tmp_link, "Ephemeral direct download link (expires in <1 minute)")
    result.links << Link.new("/#{repo_owner}/#{repo_name}/artifact/#{artifact_id}")
    result.links << Link.new(
      "https://github.com/#{repo_owner}/#{repo_name}/suites/#{check_suite_id}/artifacts/#{artifact_id}",
      "GitHub: direct download of artifact ##{artifact_id} (requires GitHub login)", ext: true
    ) if check_suite_id
    return result
  end

  @[ART::Get("/:repo_owner/:repo_name/run/:run_id/:artifact")]
  def by_run(repo_owner : String, repo_name : String, run_id : Int64, artifact : String, check_suite_id : Int64? = nil) : ArtifactsController::Result
    token = AppClient.token(RepoInstallations.read(repo_owner))
    Artifacts.for_run(repo_owner, repo_name, run_id, token) do |art|
      if art.name == artifact
        result = by_artifact(repo_owner, repo_name, art.id, check_suite_id)
        result.title = "Repository #{repo_owner}/#{repo_name} | Run ##{run_id} | Artifact #{artifact}"
        result.links << Link.new("/#{repo_owner}/#{repo_name}/run/#{run_id}/#{artifact}")
        result.links << Link.new(
          "https://github.com/#{repo_owner}/#{repo_name}/actions/runs/#{run_id}",
          "GitHub: view run ##{run_id}", ext: true
        )
        return result
      end
    end
    raise ART::Exceptions::NotFound.new("No artifacts found for this run")
  end

  @[ART::Get("/:repo_owner/:repo_name/:workflow/:branch/:artifact")]
  def by_branch(repo_owner : String, repo_name : String, workflow : String, branch : String, artifact : String) : ArtifactsController::Result
    token = AppClient.token(RepoInstallations.read(repo_owner))
    workflow += ".yml" unless workflow.to_i? || workflow.ends_with?(".yml")
    WorkflowRuns.for_workflow(repo_owner, repo_name, workflow, branch, token, max_items: 1) do |run|
      result = by_run(repo_owner, repo_name, run.id, artifact, run.check_suite_url.rpartition("/").last.to_i64?)
      result.title = "Repository #{repo_owner}/#{repo_name} | Workflow #{workflow} | Branch #{branch} | Artifact #{artifact}"
      result.links << Link.new("/#{repo_owner}/#{repo_name}/#{workflow.rchop(".yml")}/#{branch}/#{artifact}")
      result.links << Link.new("https://github.com/#{repo_owner}/#{repo_name}/actions?" + HTTP::Params.encode({
        query: "event:push is:success workflow:#{workflow} branch:#{branch}",
      }), "GitHub: browse runs for workflow '#{workflow}' on branch '#{branch}'", ext: true)
      return result
    end
    raise ART::Exceptions::NotFound.new("No artifacts found for workflow and branch")
  end

  view Result do
    title = result.title
    links = result.links.reverse!
    ART::Response.new(headers: HTML_HEADERS) do |io|
      ECR.embed("head.html", io)
      ECR.embed("artifact.html", io)
    end
  end
end

class FormController < ART::Controller
  @[ART::Get("/")]
  def index : ART::Response
    ART::Response.new(headers: HTML_HEADERS) do |io|
      ECR.embed("head.html", io)
      ECR.embed("README.html", io)
    end
  end

  @[ART::Post("/")]
  def to_artifact_page(request : HTTP::Request) : ART::RedirectResponse
    data = HTTP::Params.parse(request.body.not_nil!.gets_to_end)
    ART::RedirectResponse.new(
      "/#{data["repo_owner"]}/#{data["repo_name"]}/#{data["workflow"]}/#{data["branch"]}/#{data["artifact"]}"
    )
  end
end

ART.run
