module ResilientReads
  class Railtie < Rails::Railtie
    initializer "resilient_reads.configure_logger" do
      ResilientReads.config.logger ||= Rails.logger
    end

    # Set up replica pools and patch the adapter after AR is ready.
    initializer "resilient_reads.setup", after: "active_record.initialize_database" do
      ActiveSupport.on_load(:active_record) do
        ResilientReads.setup_replicas!
        ResilientReads.patch_adapter!
        ResilientReads.start_health_checker!
      end
    end

    # Insert middleware for by_default mode.
    initializer "resilient_reads.middleware" do |app|
      app.middleware.insert_before 0, ResilientReads::Middleware
    end

    # Restart health checker after Puma/Unicorn forks.
    config.after_initialize do
      if defined?(::Puma) || defined?(::Unicorn)
        ActiveSupport.on_load(:active_record) do
          if ActiveRecord::Base.respond_to?(:connection_pool)
            at_exit { ResilientReads.stop_health_checker! }
          end
        end
      end

      if defined?(::Puma)
        Puma::Plugin.create do
          def start(launcher)
            launcher.events.on_booted do
              ResilientReads.restart_health_checker!
            end
          end
        end rescue nil
      end
    end
  end
end
