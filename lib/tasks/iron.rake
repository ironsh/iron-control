# Operator/developer convenience tasks for seeding the control plane:
# principals, static secrets, proxies, grants, and principal<->proxy assignment.
#
# Arguments are passed as environment variables so invocations are explicit and
# shell-friendly. References (PRINCIPAL, SECRET, PROXY) accept an oid, a
# foreign_id (within NAMESPACE), or a name.
#
#   bin/rails iron:principal:add NAME=ci-runner FOREIGN_ID=ci-runner
#   bin/rails iron:secret:add NAME=acme-api-key VALUE=sk_test_123 HEADER=Authorization
#   bin/rails iron:grant:add PRINCIPAL=ci-runner SECRET=acme-api-key
#   bin/rails iron:proxy:add NAME=edge-1 PRINCIPAL=ci-runner
#   bin/rails iron:proxy:assign PROXY=edge-1 PRINCIPAL=ci-runner
#
# List anything with iron:<resource>:list.

module IronTasks
  module_function

  def env(key, default = nil)
    value = ENV[key]
    value.nil? || value.strip.empty? ? default : value.strip
  end

  def require_env(key)
    env(key) || abort("Missing required env var: #{key}")
  end

  def namespace
    env("NAMESPACE", "default")
  end

  # LABELS="team=payments,env=dev" -> {"team"=>"payments","env"=>"dev"}
  def labels
    raw = env("LABELS")
    return {} unless raw
    raw.split(",").to_h do |pair|
      key, value = pair.split("=", 2)
      [ key.to_s.strip, value.to_s.strip ]
    end
  end

  # The user recorded as created_by. Defaults to the bootstrap user, falling
  # back to the first user; override with ACTOR_EMAIL.
  def actor
    email = env("ACTOR_EMAIL") || ENV["IRON_CONTROL_INITIAL_USER_EMAIL"].to_s.strip.presence
    user = email ? User.find_by(email: email) : User.first
    user || abort("No user found. Run `just dev` once to bootstrap a user, or set ACTOR_EMAIL.")
  end

  def find_principal!(ref)
    resolve(Principal, ref) || abort("Principal not found: #{ref}")
  end

  def find_static_secret!(ref)
    resolve(StaticSecret, ref) || abort("Static secret not found: #{ref}")
  end

  # Proxies have neither namespace nor foreign_id; resolve by oid or name.
  def find_proxy!(ref)
    Proxy.find_by_oid(ref) || Proxy.find_by(name: ref) || abort("Proxy not found: #{ref}")
  end

  # oid, then (namespace, foreign_id), then name.
  def resolve(model, ref)
    model.find_by_oid(ref) ||
      model.find_by(namespace: namespace, foreign_id: ref) ||
      model.find_by(name: ref)
  end
end

namespace :iron do
  namespace :principal do
    desc "Create a principal. Env: [NAME], [FOREIGN_ID], [NAMESPACE=default], [LABELS=k=v,..]"
    task add: :environment do
      principal = Principal.create!(
        name: IronTasks.env("NAME"),
        namespace: IronTasks.namespace,
        foreign_id: IronTasks.env("FOREIGN_ID"),
        labels: IronTasks.labels,
        created_by: IronTasks.actor
      )
      puts "Created principal #{principal.oid} " \
           "(name=#{principal.name.inspect} namespace=#{principal.namespace} foreign_id=#{principal.foreign_id.inspect})"
    end

    desc "List principals."
    task list: :environment do
      Principal.order(:id).each do |p|
        puts [ p.oid, p.namespace, p.foreign_id || "-", p.name || "-" ].join("\t")
      end
    end
  end

  namespace :secret do
    desc "Create a control-plane static secret. Env: VALUE; [NAME], [FOREIGN_ID], " \
         "[HEADER=Authorization], [FORMATTER], [QUERY_PARAM], [NAMESPACE=default], [LABELS]"
    task add: :environment do
      inject =
        if (param = IronTasks.env("QUERY_PARAM"))
          { "query_param" => param }
        else
          config = { "header" => IronTasks.env("HEADER", "Authorization") }
          formatter = IronTasks.env("FORMATTER")
          config["formatter"] = formatter if formatter
          config
        end

      secret = StaticSecret.new(
        name: IronTasks.env("NAME"),
        namespace: IronTasks.namespace,
        foreign_id: IronTasks.env("FOREIGN_ID"),
        labels: IronTasks.labels,
        inject_config: inject,
        created_by: IronTasks.actor
      )
      # control_plane stores the value encrypted in the control plane and
      # delivers it inline on sync. A source is required for the secret to be
      # deliverable to a proxy.
      secret.build_source(source_type: "control_plane", secret: IronTasks.require_env("VALUE"))
      secret.save!

      puts "Created static secret #{secret.oid} (source=control_plane, inject=#{inject.to_json})"
    end

    desc "List static secrets."
    task list: :environment do
      StaticSecret.order(:id).each do |s|
        puts [ s.oid, s.namespace, s.foreign_id || "-", s.name || "-", s.source&.source_type || "(no source)" ].join("\t")
      end
    end
  end

  namespace :grant do
    desc "Grant a static secret to a principal. Env: PRINCIPAL, SECRET, [NAMESPACE=default]"
    task add: :environment do
      grant = Grant.create!(
        principal: IronTasks.find_principal!(IronTasks.require_env("PRINCIPAL")),
        static_secret: IronTasks.find_static_secret!(IronTasks.require_env("SECRET")),
        created_by: IronTasks.actor
      )
      puts "Created grant #{grant.oid}: principal #{grant.principal.oid} -> static_secret #{grant.static_secret.oid}"
    end

    desc "List grants."
    task list: :environment do
      Grant.includes(:principal, :static_secret).order(:id).each do |g|
        puts [ g.oid, g.grantee&.oid || "-", g.grantable&.oid || "-" ].join("\t")
      end
    end
  end

  namespace :proxy do
    desc "Create a proxy, optionally assigned. Env: NAME; [PRINCIPAL], [NAMESPACE=default]"
    task add: :environment do
      ref = IronTasks.env("PRINCIPAL")
      proxy = Proxy.create!(
        name: IronTasks.require_env("NAME"),
        principal: ref ? IronTasks.find_principal!(ref) : nil
      )
      puts "Created proxy #{proxy.oid} (name=#{proxy.name}, status=#{proxy.status})"
      puts "Bearer token (shown once, store it now): #{proxy.token}"
    end

    desc "Assign or swap a proxy's principal. Env: PROXY, PRINCIPAL, [NAMESPACE=default]"
    task assign: :environment do
      proxy = IronTasks.find_proxy!(IronTasks.require_env("PROXY"))
      proxy.update!(principal: IronTasks.find_principal!(IronTasks.require_env("PRINCIPAL")))
      puts "Proxy #{proxy.oid} now assigned to principal #{proxy.principal.oid} (#{proxy.status})"
    end

    desc "Unassign a proxy's principal. Env: PROXY"
    task unassign: :environment do
      proxy = IronTasks.find_proxy!(IronTasks.require_env("PROXY"))
      proxy.update!(principal: nil)
      puts "Proxy #{proxy.oid} is now #{proxy.status}"
    end

    desc "List proxies."
    task list: :environment do
      Proxy.includes(:principal).order(:id).each do |px|
        puts [ px.oid, px.name, px.status, px.principal&.oid || "-" ].join("\t")
      end
    end
  end
end
