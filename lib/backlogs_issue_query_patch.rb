if check_redmine_version_ge(2, 3)
  require_dependency 'issue_query'
else
  require_dependency 'query'
end
require 'erb'

module Backlogs
  class RbERB
    def initialize(s)
      @sql = ERB.new(s)
    end

    def to_s
      return @sql.result
    end
  end

  module IssueQueryPatch
    def self.included(base) # :nodoc:
      base.extend(ClassMethods)
      base.send(:include, InstanceMethods)

      # Same as typing in the class
      base.class_eval do
        unloadable # Send unloadable so it will not be unloaded in development

        alias_method_chain :available_filters, :backlogs_issue_type
        alias_method_chain :available_columns, :backlogs_issue_type
        alias_method_chain :sql_for_field, :backlogs_issue_type
        alias_method_chain :joins_for_order_statement, :backlogs_issue_type
      end
    end

    module InstanceMethods
      def joins_for_order_statement_with_backlogs_issue_type(order_options)
        joins = joins_for_order_statement_without_backlogs_issue_type(order_options)
        joins
      end

      def available_filters_with_backlogs_issue_type
        @available_filters = available_filters_without_backlogs_issue_type
        return @available_filters if !show_backlogs_issue_items?(project)

        if RbStory.trackers.length == 0 or RbTask.tracker.blank?
          backlogs_filters = { }
        else
          backlogs_filters = {
            # mother of *&@&^*@^*#.... order "20" is a magical constant in RM2.2 which means "I'm a custom field". What. The. Fuck.
            "backlogs_issue_type" => {  :type => :list,
                                        :name => l(:field_backlogs_issue_type),
                                        :values => [[l(:backlogs_story), "story"], [l(:backlogs_task), "task"], [l(:backlogs_impediment), "impediment"], [l(:backlogs_any), "any"]],
                                        :order => 21 },
            "story_points" => { :type => :float,
                                :name => l(:field_story_points),
                                :order => 22 }
            }
        end

        backlogs_filters["releases"] = { :type => :list_optional,
                          :name => l(:field_releases),
                          :values => lambda { project.releases.collect{|s| [s.name, s.id.to_s] } },
                          :order => 23
                        }

        if check_redmine_version_ge(3, 4)
          backlogs_filters.each do |field, filter|
            options = {:type => filter[:type], :name => filter[:name], :values => filter[:values]}
            add_available_filter(field, options)
          end
        else
          @available_filters = @available_filters.merge(backlogs_filters)
        end
        @available_filters
      end
      
      def available_columns_with_backlogs_issue_type
        @available_columns = available_columns_without_backlogs_issue_type
        return @available_columns if !show_backlogs_issue_items?(project) or @backlog_columns_included
        
        @backlog_columns_included = true
        
        @available_columns << QueryColumn.new(:story_points, :sortable => "#{Issue.table_name}.story_points")
        @available_columns << QueryColumn.new(:velocity_based_estimate)
        @available_columns << QueryColumn.new(:position, :sortable => "#{Issue.table_name}.position")
        @available_columns << QueryColumn.new(:remaining_hours, :sortable => "#{Issue.table_name}.remaining_hours")
        @available_columns << QueryColumn.new(:releases, :sortable => "#{RbIssueRelease.table_name}.release_id")
        @available_columns << QueryColumn.new(:backlogs_issue_type)
      end

      def sql_for_field_with_backlogs_issue_type(field, operator, value, db_table, db_field, is_custom_filter=false)
        if field == "releases"
        else
          return sql_for_field_without_backlogs_issue_type(field, operator, value, db_table, db_field, is_custom_filter) unless field == "backlogs_issue_type"
        end
        db_table = Issue.table_name

        sql = []

        selected_values = values_for(field)
        selected_values = ['story', 'task'] if selected_values.include?('any')

        story_trackers = RbStory.trackers(:type=>:string)
        all_trackers = (RbStory.trackers + [RbTask.tracker]).collect{|val| "#{val}"}.join(",")

        selected_values.each { |val|
          case val
            when "story"
              sql << "(#{db_table}.tracker_id in (#{story_trackers}))"

            when "task"
              sql << "(#{db_table}.tracker_id = #{RbTask.tracker})"

            when "impediment"
              sql << "(#{db_table}.id in (
                                select issue_from_id
                                from issue_relations ir
                                join issues blocked on
                                  blocked.id = ir.issue_to_id
                                  and blocked.tracker_id in (#{all_trackers})
                                where ir.relation_type = 'blocks'
                              ))"
          end
        }
        case operator
          when "="
            if field == "releases"
              issue_ids = RbIssueRelease.where("release_id IN(?)", value).pluck(:issue_id).uniq
              sql = queried_class.send(:sanitize_sql_for_conditions, ["#{db_table}.id IN (?)", issue_ids])
            else
              sql = sql.join(" or ")
            end
          when "!"
            if field == "releases"
              issue_ids = RbIssueRelease.where("release_id IN(?)", value).pluck(:issue_id).uniq
              sql = queried_class.send(:sanitize_sql_for_conditions, ["#{db_table}.id NOT IN (?)", issue_ids])
            else
              sql = "not (" + sql.join(" or ") + ")"
            end
          when "!*"
            if field == "releases"
              issue_ids = RbIssueRelease.pluck(:issue_id).uniq
              sql = queried_class.send(:sanitize_sql_for_conditions, ["#{db_table}.id NOT IN (?)", issue_ids])
            end
          when "*"
            if field == "releases"
              issue_ids = RbIssueRelease.pluck(:issue_id).uniq
              sql = queried_class.send(:sanitize_sql_for_conditions, ["#{db_table}.id IN (?)", issue_ids])
            end
        end

        return sql
      end
      
      private
      def show_backlogs_issue_items?(project)
        !project.nil? and project.module_enabled?('backlogs')
      end
    end

    module ClassMethods
      # Setter for +available_columns+ that isn't provided by the core.
      def available_columns=(v)
        self.available_columns = (v)
      end

      # Method to add a column to the +available_columns+ that isn't provided by the core.
      def add_available_column(column)
        self.available_columns << (column)
      end
      
    end
  end
end

if check_redmine_version_ge(2, 3)
  IssueQuery.send(:include, Backlogs::IssueQueryPatch) unless IssueQuery.included_modules.include? Backlogs::IssueQueryPatch
else
  Query.send(:include, Backlogs::IssueQueryPatch) unless Query.included_modules.include? Backlogs::IssueQueryPatch
end
