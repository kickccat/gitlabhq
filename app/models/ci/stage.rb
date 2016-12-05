module Ci
  # Currently this is artificial object, constructed dynamically
  # We should migrate this object to actual database record in the future
  class Stage
    include StaticModel

    attr_reader :pipeline, :name

    delegate :project, to: :pipeline

    def initialize(pipeline, name: name, status: nil)
      @pipeline, @name, @status = pipeline, name, status
    end

    def to_param
      name
    end

    def status
      @status ||= statuses.latest.status
    end

    def statuses
      @statuses ||= pipeline.statuses.where(stage: stage)
    end

    def builds
      @builds ||= pipeline.builds.where(stage: stage)
    end
  end
end
