# frozen_string_literal: true

# A human who can sign in to the web UI.
#
# Passwords are stored as salted PBKDF2-HMAC-SHA256 (OpenSSL, no extra gem)
# in the form "pbkdf2$<iterations>$<salt b64>$<hash b64>". Accounts lock for
# LOCK_FOR after MAX_FAILED_ATTEMPTS consecutive bad passwords.
class User < ApplicationRecord
  ITERATIONS = Rails.env.test? ? 1_000 : 600_000
  MAX_FAILED_ATTEMPTS = 5
  LOCK_FOR = 15.minutes
  MIN_PASSWORD_LENGTH = 10
  USERNAME_FORMAT = /\A[a-z0-9][a-z0-9._@-]{1,63}\z/

  # admin: everything, including user management. member: view + cancel.
  enum :role, { member: 0, admin: 1 }

  # Set by the env bootstrap: the operator chose that password explicitly.
  attr_accessor :skip_password_policy
  attr_reader :password

  normalizes :username, with: ->(u) { u.to_s.strip.downcase }

  validates :username, presence: true, uniqueness: true, format: { with: USERNAME_FORMAT, allow_blank: true,
                                                                   message: "must be 2-64 chars: a-z 0-9 . _ @ -" }
  validates :password_digest, presence: true
  validate :password_meets_policy, if: -> { @password && !skip_password_policy }

  before_validation { self.session_nonce ||= SecureRandom.hex(16) }
  before_destroy :keep_last_admin
  before_update :keep_last_admin_on_demotion

  # --- passwords -------------------------------------------------------------

  def password=(plain)
    @password = plain.to_s
    return if @password.empty?

    self.password_digest = self.class.digest(@password)
    # New password => every existing session stops being valid.
    self.session_nonce = SecureRandom.hex(16) unless new_record?
  end

  def self.digest(plain, salt: SecureRandom.bytes(16), iterations: ITERATIONS)
    hash = OpenSSL::PKCS5.pbkdf2_hmac(plain, salt, iterations, 32, "sha256")
    ["pbkdf2", iterations, Base64.strict_encode64(salt), Base64.strict_encode64(hash)].join("$")
  end

  def self.digest_matches?(digest, plain)
    scheme, iterations, salt, hash = digest.to_s.split("$", 4)
    return false unless scheme == "pbkdf2" && hash

    expected = Base64.strict_decode64(hash)
    actual = OpenSSL::PKCS5.pbkdf2_hmac(plain.to_s, Base64.strict_decode64(salt), iterations.to_i, expected.bytesize, "sha256")
    ActiveSupport::SecurityUtils.secure_compare(actual, expected)
  rescue ArgumentError
    false
  end

  # A throwaway digest so unknown usernames cost the same as known ones.
  DUMMY_DIGEST = digest("forge-ci-dummy-password", salt: "0" * 16)

  # Returns the user on success, nil on any failure (unknown user, bad
  # password, locked). Failure bookkeeping is done here so callers can't
  # forget it.
  def self.authenticate(username, password)
    user = find_by(username: normalize_value_for(:username, username))
    unless user
      digest_matches?(DUMMY_DIGEST, password)
      return nil
    end
    return nil if user.locked?

    if digest_matches?(user.password_digest, password)
      user.update_columns(failed_attempts: 0, locked_until: nil, last_login_at: Time.current)
      user
    else
      user.register_failed_attempt!
      nil
    end
  end

  def locked?
    locked_until.present? && locked_until.future?
  end

  def register_failed_attempt!
    attempts = failed_attempts + 1
    if attempts >= MAX_FAILED_ATTEMPTS
      update_columns(failed_attempts: 0, locked_until: LOCK_FOR.from_now)
    else
      update_columns(failed_attempts: attempts)
    end
  end

  # Invalidate every session of this user.
  def rotate_session_nonce!
    update_columns(session_nonce: SecureRandom.hex(16))
  end

  # --- bootstrap -------------------------------------------------------------

  # First-run convenience: while there are no users, create an admin from
  # FORGE_CI_UI_USER / FORGE_CI_UI_PASSWORD (the old basic-auth variables).
  # In development with nothing configured, fall back to admin/password.
  def self.bootstrap_admin_from_env!
    return nil if exists?

    name = ENV["FORGE_CI_UI_USER"].presence
    pass = ENV["FORGE_CI_UI_PASSWORD"].presence
    if name.nil? || pass.nil?
      return nil unless Rails.env.development?

      name = "admin"
      pass = "password"
    end
    user = new(username: name, password: pass, role: :admin)
    user.skip_password_policy = true
    user.save!
    Rails.logger.warn("[forge-ci] created first admin '#{user.username}' from FORGE_CI_UI_USER/PASSWORD — " \
                      "change the password in the UI (Account) and then remove those variables")
    user
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    nil
  end

  def inspect
    "#<User id: #{id}, username: #{username.inspect}, role: #{role.inspect}, password_digest: [FILTERED]>"
  end

  private

  def password_meets_policy
    return if @password.length >= MIN_PASSWORD_LENGTH

    errors.add(:password, "must be at least #{MIN_PASSWORD_LENGTH} characters")
  end

  def keep_last_admin
    return unless admin? && User.admin.where.not(id: id).none?

    errors.add(:base, "cannot remove the last admin")
    throw :abort
  end

  def keep_last_admin_on_demotion
    return unless role_changed? && role_was == "admin" && User.admin.where.not(id: id).none?

    errors.add(:role, "cannot demote the last admin")
    throw :abort
  end
end
