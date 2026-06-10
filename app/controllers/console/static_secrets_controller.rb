module Console
  # Create/edit form for StaticSecret: an inject XOR replace config (enforced by
  # the model), one optional source, and any number of request rules.
  class StaticSecretsController < BaseSecretsController
    private

    def model
      StaticSecret
    end

    def kind
      "static"
    end

    def assign_form(secret)
      st = params.fetch(:static, ActionController::Parameters.new)
      if st[:mode] == "replace"
        secret.inject_config = nil
        secret.replace_config = build_replace_config(st)
      else
        secret.replace_config = nil
        secret.inject_config = build_inject_config(st)
      end
      assign_source(secret, :source)
      assign_rules(secret)
    end

    def build_inject_config(st)
      cfg = {}
      cfg["header"] = st[:header].strip if st[:header].present?
      cfg["query_param"] = st[:query_param].strip if st[:query_param].present?
      cfg["formatter"] = st[:formatter] if st[:formatter].present?
      cfg.presence
    end

    def build_replace_config(st)
      cfg = { "proxy_value" => st[:proxy_value].to_s }
      headers = split_list(st[:match_headers])
      cfg["match_headers"] = headers if headers.any?
      cfg["match_body"] = true if boolean(st[:match_body])
      cfg["match_path"] = true if boolean(st[:match_path])
      cfg["match_query"] = true if boolean(st[:match_query])
      cfg["require"] = true if boolean(st[:require])
      cfg
    end
  end
end
