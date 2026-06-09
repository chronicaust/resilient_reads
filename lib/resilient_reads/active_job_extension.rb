module ResilientReads
  # Mix into ActiveJob::Base to provide a class-level +distribute_reads+
  # macro that wraps the entire +perform+ in a distribute_reads block.
  #
  #   class ReportJob < ApplicationJob
  #     distribute_reads
  #     def perform; ... end
  #   end
  #
  module ActiveJobExtension
    extend ActiveSupport::Concern

    class_methods do
      def distribute_reads(**options)
        around_perform do |_job, block|
          ResilientReads.run(**options, &block)
        end
      end
    end
  end
end
