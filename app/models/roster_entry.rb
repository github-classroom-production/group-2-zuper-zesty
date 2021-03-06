# frozen_string_literal: true

class RosterEntry < ApplicationRecord
  class IdentifierCreationError < StandardError; end

  include Sortable
  include Searchable
  include DuplicateRosterEntries

  belongs_to :roster
  belongs_to :user, optional: true

  validates :identifier, presence: true
  validates :roster,     presence: true

  scope :order_by_repo_created_at, lambda { |context|
    assignment = context[:assignment]
    sql_formatted_assignment_id = assignment.id

    order("assignment_repos.created_at")
      .joins <<~SQL
        LEFT OUTER JOIN assignment_repos
        ON roster_entries.user_id = assignment_repos.user_id
        AND assignment_repos.assignment_id='#{sql_formatted_assignment_id}'
      SQL
  }

  scope :order_by_student_identifier, ->(_context = nil) { order(identifier: :asc) }

  scope :search_by_student_identifier, ->(query) { where("identifier ILIKE ?", "%#{query}%") }

  def self.sort_modes
    {
      "Student identifier" => :order_by_student_identifier,
      "Created at" => :order_by_repo_created_at
    }
  end

  def self.search_mode
    :search_by_student_identifier
  end

  # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity
  def self.to_csv(user_to_group_map = {})
    CSV.generate(headers: true, col_sep: ",", force_quotes: true) do |csv|
      columns = %i[identifier github_username github_id name]
      columns << :group_name unless user_to_group_map.empty?
      csv << columns

      all.sort_by(&:identifier).each do |entry|
        github_user = entry.user.try(:github_user)
        login = github_user.try(:login) || ""
        github_id = github_user.try(:id) || ""
        name = github_user.try(:name) || ""
        group_name = user_to_group_map.empty? ? "" : user_to_group_map[entry.user_id]

        row = [entry.identifier, login, github_id, name]
        row << group_name if group_name.present?
        csv << row
      end
    end
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity

  # Orders the relation for display in a view.
  # Ordering is:
  # first:  Accepted the assignment
  # second: Linked but not accepted
  # last:   Unlinked student
  #
  # with a secondary sort on ID to ensure ties are always handled in the same way
  def self.order_for_view(assignment)
    users_with_repo = assignment.repos.pluck(:user_id)
    sql_formatted_users = users_with_repo.empty? ? "(NULL)" : "(#{users_with_repo.join(',')})"

    order <<~SQL
      CASE
        WHEN roster_entries.user_id IS NULL THEN 2                   /* Not linked */
        WHEN roster_entries.user_id IN #{sql_formatted_users} THEN 0 /* Accepted */
        ELSE 1                                                       /* Linked but not accepted */
      END
    SQL
  end

  # Restrict relation to only entries that have not joined a team
  def self.students_not_on_team(group_assignment)
    students_on_team = group_assignment
      .repos
      .includes(:repo_accesses)
      .flat_map(&:repo_accesses)
      .map(&:user_id)
      .uniq
    where(user_id: nil).or(where.not(user_id: students_on_team))
  end

  # Takes an array of identifiers and creates a
  # roster entry for each. Omits duplicates, and
  # raises IdentifierCreationError if there is an
  # error.
  #
  # Returns the created entries.

  # rubocop:disable Metrics/MethodLength
  def self.create_entries(identifiers:, roster:, lms_user_ids: [])
    created_entries = []
    RosterEntry.transaction do
      identifiers = add_suffix_to_duplicates(
        identifiers: identifiers,
        existing_roster_entries: RosterEntry.where(roster: roster).pluck(:identifier)
      )

      identifiers.zip(lms_user_ids).each do |identifier, lms_user_id|
        roster_entry = RosterEntry.create(identifier: identifier, roster: roster, lms_user_id: lms_user_id)

        if !roster_entry.persisted?
          raise IdentifierCreationError unless roster_entry.errors.include?(:identifier)
        else
          created_entries << roster_entry
        end
      end
    end

    created_entries
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize
end
