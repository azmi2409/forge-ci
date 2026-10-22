# frozen_string_literal: true

# Scales runner Auto Scaling Groups up from zero when jobs queue for them.
#
#   FORGE_CI_AUTOSCALE="spot=ci-spot-runners:4,deploy=ci-deploy-runner:1"
#
# Each entry is resource_class=asg-name[:max[:jobs_per_instance]] (max
# defaults to 1, jobs per instance to 1). Classless jobs, which any runner
# may claim, count toward the first entry.
#
# This only ever raises a group's desired capacity, to cover the queued and
# running jobs of its class. Scaling down is the runners' job: with
# IDLE_SHUTDOWN_AFTER and bin/forge-ci-asg-terminate-self an idle runner
# stops claiming and then removes its own instance, so nothing is ever
# terminated in the middle of a job.
#
# FORGE_CI_AUTOSCALE_WARM="deploy" (comma-separated classes) also counts
# that class's jobs still waiting on earlier jobs, so its runner boots while
# the checks run instead of after them. The runner then stays up until the
# job arrives (the claim response's `upcoming`), or idles out as usual if the
# job is canceled because a check failed.
#
# AWS credentials come from the usual SDK chain (the same AWS_* variables as
# S3); FORGE_CI_AUTOSCALE_REGION overrides AWS_REGION for the groups.
class RunnerAutoscaler
  Group = Struct.new(:resource_class, :asg_name, :max, :jobs_per_instance, keyword_init: true)

  class ConfigError < StandardError; end

  def self.groups(spec = ENV["FORGE_CI_AUTOSCALE"])
    spec.to_s.split(",").map(&:strip).reject(&:empty?).map do |entry|
      klass, rest = entry.split("=", 2)
      name, max, per = rest.to_s.split(":")
      raise ConfigError, "FORGE_CI_AUTOSCALE entry #{entry.inspect} needs resource_class=asg-name" if klass.blank? || name.blank?

      Group.new(resource_class: klass.strip, asg_name: name.strip,
                max: Integer(max.presence || 1), jobs_per_instance: [Integer(per.presence || 1), 1].max)
    end
  end

  def self.warm_classes(spec = ENV["FORGE_CI_AUTOSCALE_WARM"])
    spec.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  def self.enabled?
    ENV["FORGE_CI_AUTOSCALE"].present?
  end

  # Factory seam: tests swap in a fake client.
  class << self
    attr_writer :client_factory

    def client_factory
      @client_factory ||= lambda do
        require "aws-sdk-autoscaling"
        region = ENV["FORGE_CI_AUTOSCALE_REGION"].presence || ENV["AWS_REGION"]
        Aws::AutoScaling::Client.new(**{ region: region }.compact)
      end
    end
  end

  def initialize(groups: self.class.groups, client: nil)
    @groups = groups
    @client = client
  end

  # Returns { asg_name => desired capacity it was raised to } for the groups changed.
  def call
    @groups.each_with_index.with_object({}) do |(group, index), changed|
      wanted = wanted_capacity(group, include_classless: index.zero?)
      next if wanted.zero?

      current = current_capacity(group.asg_name)
      next if current.nil? || current >= wanted

      client.set_desired_capacity(auto_scaling_group_name: group.asg_name, desired_capacity: wanted, honor_cooldown: false)
      Rails.logger.info("[autoscale] #{group.asg_name}: desired capacity #{current} -> #{wanted}")
      changed[group.asg_name] = wanted
    end
  end

  # Instances needed for the class's queued and in-flight jobs, capped at max.
  def wanted_capacity(group, include_classless: false)
    classes = [group.resource_class]
    classes << nil if include_classless
    statuses = %w[queued claimed running]
    jobs = JobRun.where(resource_class: classes, status: statuses).count
    jobs += JobRun.upcoming_count(group.resource_class) if self.class.warm_classes.include?(group.resource_class)
    [(jobs.to_f / group.jobs_per_instance).ceil, group.max].min
  end

  private

  def client
    @client ||= self.class.client_factory.call
  end

  def current_capacity(asg_name)
    group = client.describe_auto_scaling_groups(auto_scaling_group_names: [asg_name]).auto_scaling_groups.first
    if group.nil?
      Rails.logger.warn("[autoscale] Auto Scaling Group #{asg_name.inspect} not found")
      return nil
    end
    group.desired_capacity
  end
end
