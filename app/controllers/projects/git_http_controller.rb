class Projects::GitHttpController < Projects::ApplicationController
  skip_before_action :repository
  before_action :authenticate_user
  before_action :ensure_project_found?

  # GET /foo/bar.git/info/refs?service=git-upload-pack (git pull)
  # GET /foo/bar.git/info/refs?service=git-receive-pack (git push)
  def info_refs
    if upload_pack? && upload_pack_allowed?
      render_ok
    elsif receive_pack? && receive_pack_allowed?
      render_ok
    else
      render_not_found
    end
  end

  # POST /foo/bar.git/git-upload-pack (git pull)
  def git_upload_pack
    if upload_pack? && upload_pack_allowed?
      render_ok
    else
      render_not_found
    end
  end

  # POST /foo/bar.git/git-receive-pack" (git push)
  def git_receive_pack
    if receive_pack? && receive_pack_allowed?
      render_ok
    else
      render_not_found
    end
  end

  private

  def authenticate_user
    return if project && project.public? && upload_pack?

    authenticate_or_request_with_http_basic do |login, password|
      return @ci = true if valid_ci_request?(login, password)

      @user = Gitlab::Auth.new.find(login, password)
      @user ||= oauth_access_token_check(login, password)
      rate_limit_ip!(login, @user)
    end
  end

  def ensure_project_found?
    render_not_found if project.blank?
  end

  def valid_ci_request?(login, password)
    matched_login = /(?<service>^[a-zA-Z]*-ci)-token$/.match(login)

    if project && matched_login.present? && upload_pack?
      underscored_service = matched_login['service'].underscore

      if underscored_service == 'gitlab_ci'
        return project && project.valid_build_token?(password)
      elsif Service.available_services_names.include?(underscored_service)
        # We treat underscored_service as a trusted input because it is included
        # in the Service.available_services_names whitelist.
        service_method = "#{underscored_service}_service"
        service = project.send(service_method)

        return service && service.activated? && service.valid_token?(password)
      end
    end

    false
  end

  def oauth_access_token_check(login, password)
    if login == "oauth2" && upload_pack? && password.present?
      token = Doorkeeper::AccessToken.by_token(password)
      token && token.accessible? && User.find_by(id: token.resource_owner_id)
    end
  end

  def rate_limit_ip!(login, user)
    # If the user authenticated successfully, we reset the auth failure count
    # from Rack::Attack for that IP. A client may attempt to authenticate
    # with a username and blank password first, and only after it receives
    # a 401 error does it present a password. Resetting the count prevents
    # false positives from occurring.
    #
    # Otherwise, we let Rack::Attack know there was a failed authentication
    # attempt from this IP. This information is stored in the Rails cache
    # (Redis) and will be used by the Rack::Attack middleware to decide
    # whether to block requests from this IP.

    config = Gitlab.config.rack_attack.git_basic_auth
    return user unless config.enabled

    if user
      # A successful login will reset the auth failure count from this IP
      Rack::Attack::Allow2Ban.reset(request.ip, config)
    else
      banned = Rack::Attack::Allow2Ban.filter(request.ip, config) do
        # Unless the IP is whitelisted, return true so that Allow2Ban
        # increments the counter (stored in Rails.cache) for the IP
        if config.ip_whitelist.include?(request.ip)
          false
        else
          true
        end
      end

      if banned
        Rails.logger.info "IP #{request.ip} failed to login " \
          "as #{login} but has been temporarily banned from Git auth"
      end
    end

    user
  end

  def project
    return @project if defined?(@project)

    project_id, _ = project_id_with_suffix
    if project_id.blank?
      @project = nil
    else
      @project = Project.find_with_namespace("#{params[:namespace_id]}/#{project_id}")
    end
  end

  # This method returns two values so that we can parse
  # params[:project_id] (untrusted input!) in exactly one place.
  def project_id_with_suffix
    id = params[:project_id] || ''

    %w{.wiki.git .git}.each do |suffix|
      if id.end_with?(suffix)
        # Be careful to only remove the suffix from the end of 'id'.
        # Accidentally removing it from the middle is how security
        # vulnerabilities happen!
        return [id.slice(0, id.length - suffix.length), suffix]
      end
    end

    # Something is wrong with params[:project_id]; do not pass it on.
    [nil, nil]
  end

  def repository
    @repository ||= begin
      _, suffix = project_id_with_suffix
      if suffix == '.wiki.git'
        project.wiki.repository
      else
        project.repository
      end
    end
  end

  def upload_pack?
    git_command == 'git-upload-pack'
  end

  def receive_pack?
    git_command == 'git-receive-pack'
  end

  def git_command
    if action_name == 'info_refs'
      params[:service]
    else
      action_name.gsub('_', '-')
    end
  end

  def render_ok
    render json: Gitlab::Workhorse.git_http_ok(repository, user)
  end

  def render_not_found
    render text: 'Not Found', status: :not_found
  end

  def ci?
    !!@ci
  end

  def user
    @user
  end

  def upload_pack_allowed?
    if !Gitlab.config.gitlab_shell.upload_pack
      false
    elsif ci?
      true
    elsif user
      Gitlab::GitAccess.new(user, project).download_access_check.allowed?
    else
      project.public?
    end
  end

  def receive_pack_allowed?
    if !Gitlab.config.gitlab_shell.receive_pack
      false
    elsif user
      # Skip user authorization on upload request.
      # It will be done by the pre-receive hook in the repository.
      true
    else
      false
    end
  end
end
