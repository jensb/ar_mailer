require 'test/unit'
require 'action_mailer'
require 'action_mailer/ar_sendmail'
require 'rubygems'
require 'minitest/autorun'
require 'mocha'
require 'test_helper'

class ActionMailer::ARSendmail
  attr_accessor :slept
  def sleep(secs)
    @slept ||= []
    @slept << secs
  end
end

class TestARSendmail < MiniTest::Unit::TestCase

  def setup
    ActionMailer::Base.reset
    Email.delete_all
    Net::SMTP.reset

    @sm = ActionMailer::ARSendmail.new
    @sm.verbose = true

    Net::SMTP.clear_on_start

    @include_c_e = ! $".grep(/config\/environment.rb/).empty?
    $" << 'config/environment.rb' unless @include_c_e
  end

  def teardown
    $".delete 'config/environment.rb' unless @include_c_e
  end

  def test_class_create_migration
    out, = capture_io do
      ActionMailer::ARSendmail.create_migration 'Mail'
    end

    expected = <<-EOF
class CreateMail < ActiveRecord::Migration
  def self.up
    create_table :mail do |t|
      t.column :to, :string
      t.column :from, :string
      t.column :mail, :text
      t.column :last_send_attempt, :integer, :default => 0
      t.column :last_error, :text
      t.column :success_status, :string
      t.column :attempts, :integer
      t.column :failed, :boolean, :default => false
      t.column :created_at, :datetime
      t.column :updated_at, :datetime
      t.column :sent_at, :datetime
    end

    add_index :mail, :sent_at
    add_index :mail, :failed
  end

  def self.down
    drop_table :mail
  end
end
# =============================================================================================================================
# = Warning! If you're sending emails with attachments you probably want to use LONGTEXT instead of TEXT for the :mail column =
# =============================================================================================================================
Example extra migration:

class MailMailTextToLongtext < ActiveRecord::Migration
  def self.up
    execute "ALTER TABLE mail CHANGE mail mail LONGTEXT"
  end

  def self.down
    execute "ALTER TABLE mail CHANGE mail mail TEXT"
  end
end
EOF
    assert_equal expected, out
  end

  def test_class_create_model
    out, = capture_io do
      ActionMailer::ARSendmail.create_model 'Mail'
    end

    expected = <<-EOF
class Mail < ActiveRecord::Base
  validates_presence_of :from, :to, :mail

  def sent?
    not failed? and not sent_at.nil?
  end
end
EOF

    assert_equal expected, out
  end

  def test_class_mailq
    e1 = Email.create :from => 'nobody@example.com', :to => 'recip@h1.example.com', :mail => 'body0'
    e2 = Email.create :from => 'nobody@example.com', :to => 'recip@h1.example.com', :mail => 'body1'
    last = Email.create :from => 'nobody@example.com', :to => 'recip@h2.example.com', :mail => 'body2'
    last_attempt_time = Time.parse('Thu Aug 10 2006 11:40:05')
    last.last_send_attempt = last_attempt_time.to_i

    out, err = capture_io do
      ActionMailer::ARSendmail.mailq 'Email'
    end

    expected = "-Queue ID- --Size-- ----Arrival Time---- -----Last attempt at------ -Attempts- -Sender/Recipient--------------------------------------\n#{"%10d" % e1.id}        5 #{e1.created_at.strftime '%a %b %d %H:%M:%S'}   Thu Jan 01 01:00:00 +0100 1970        0 nobody@example.com -> recip@h1.example.com\n#{"%10d" % e2.id}        5 #{e2.created_at.strftime '%a %b %d %H:%M:%S'}   Thu Jan 01 01:00:00 +0100 1970        0 nobody@example.com -> recip@h1.example.com\n#{"%10d" % last.id}        5 #{last.created_at.strftime '%a %b %d %H:%M:%S'}   Thu Jan 01 01:00:00 +0100 1970        0 nobody@example.com -> recip@h2.example.com\n-- 0 Kbytes in 3 Requests.\n"
    expected = expected % last_attempt_time.strftime('%z')
    assert_equal expected, out

  end

  def test_class_mailq_empty
    out, err = capture_io do
      ActionMailer::ARSendmail.mailq 'Email'
    end

    assert_equal "Mail queue is empty\n", out
  end

  def test_class_new
    @sm = ActionMailer::ARSendmail.new

    assert_equal 60, @sm.delay
    assert_equal Email, @sm.email_class
    assert_equal nil, @sm.once
    assert_equal nil, @sm.verbose
    assert_equal nil, @sm.batch_size

    @sm = ActionMailer::ARSendmail.new :Delay => 75, :Verbose => true,
                                       :TableName => 'Object', :Once => true,
                                       :BatchSize => 1000

    assert_equal 75, @sm.delay
    assert_equal Object, @sm.email_class
    assert_equal true, @sm.once
    assert_equal true, @sm.verbose
    assert_equal 1000, @sm.batch_size
  end

  def test_class_parse_args_batch_size
    options = ActionMailer::ARSendmail.process_args %w[-b 500]

    assert_equal 500, options[:BatchSize]

    options = ActionMailer::ARSendmail.process_args %w[--batch-size 500]

    assert_equal 500, options[:BatchSize]
  end

  def test_class_parse_args_chdir
    argv = %w[-c /tmp]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal '/tmp', options[:Chdir]

    argv = %w[--chdir /tmp]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal '/tmp', options[:Chdir]

    argv = %w[-c /nonexistent]
    
    out, err = capture_io do
      assert_raises SystemExit do
        ActionMailer::ARSendmail.process_args argv
      end
    end
  end

  def test_class_parse_args_daemon
    argv = %w[-d]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal true, options[:Daemon]

    argv = %w[--daemon]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal true, options[:Daemon]
  end
  
  def test_class_parse_args_pidfile
    argv = %w[-p ./log/ar_sendmail.pid]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal './log/ar_sendmail.pid', options[:Pidfile]

    argv = %w[--pidfile ./log/ar_sendmail.pid]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal './log/ar_sendmail.pid', options[:Pidfile]
  end
  
  def test_class_parse_args_delay
    argv = %w[--delay 75]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal 75, options[:Delay]
  end

  def test_class_parse_args_environment
    assert_equal nil, ENV['RAILS_ENV']

    argv = %w[-e production]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal 'production', options[:RailsEnv]

    assert_equal 'production', ENV['RAILS_ENV']

    argv = %w[--environment production]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal 'production', options[:RailsEnv]
  end

  def test_class_parse_args_mailq
    options = ActionMailer::ARSendmail.process_args []
    refute_includes options, :MailQ

    argv = %w[--mailq]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal true, options[:MailQ]
  end

  def test_class_parse_args_max_age
    options = ActionMailer::ARSendmail.process_args []
    assert_equal 86400 * 7, options[:MaxAge]

    argv = %w[--max-age 86400]

    options = ActionMailer::ARSendmail.process_args argv

    assert_equal 86400, options[:MaxAge]
  end

  def test_class_parse_args_migration
    options = ActionMailer::ARSendmail.process_args []
    refute_includes options, :Migration

    argv = %w[--create-migration]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal true, options[:Migrate]
  end

  def test_class_parse_args_model
    options = ActionMailer::ARSendmail.process_args []
    refute_includes options, :Model

    argv = %w[--create-model]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal true, options[:Model]
  end

  def test_class_parse_args_no_config_environment
    $".delete 'config/environment.rb'

    out, err = capture_io do
      assert_raises SystemExit do
        ActionMailer::ARSendmail.process_args []
      end
    end

  ensure
    $" << 'config/environment.rb' if @include_c_e
  end

  def test_class_parse_args_no_config_environment_migrate
    $".delete 'config/environment.rb'

    out, err = capture_io do
      ActionMailer::ARSendmail.process_args %w[--create-migration]
    end

    assert true # count

  ensure
    $" << 'config/environment.rb' if @include_c_e
  end

  def test_class_parse_args_no_config_environment_model
    $".delete 'config/environment.rb'

    out, err = capture_io do
      ActionMailer::ARSendmail.process_args %w[--create-model]
    end

    assert true # count

  rescue SystemExit
    flunk 'Should not exit'

  ensure
    $" << 'config/environment.rb' if @include_c_e
  end

  def test_class_parse_args_once
    argv = %w[-o]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal true, options[:Once]

    argv = %w[--once]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal true, options[:Once]
  end

  def test_class_parse_args_table_name
    argv = %w[-t Email]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal 'Email', options[:TableName]

    argv = %w[--table-name=Email]
    
    options = ActionMailer::ARSendmail.process_args argv

    assert_equal 'Email', options[:TableName]
  end

  def test_class_usage
    out, err = capture_io do
      assert_raises SystemExit do
        ActionMailer::ARSendmail.usage 'opts'
      end
    end

    assert_equal '', out
    assert_equal "opts\n", err

    out, err = capture_io do
      assert_raises SystemExit do
        ActionMailer::ARSendmail.usage 'opts', 'hi'
      end
    end

    assert_equal '', out
    assert_equal "hi\n\nopts\n", err
  end

  def test_cleanup
    e1 = Email.create :mail => 'body', :to => 'to', :from => 'from'
    e1.created_at = Time.now
    e2 = Email.create :mail => 'body', :to => 'to', :from => 'from'
    e3 = Email.create :mail => 'body', :to => 'to', :from => 'from'
    e3.update_attributes(:last_send_attempt => 1.day.ago, :created_at => 3.weeks.ago, :sent_at => nil)

    out, err = capture_io do
      @sm.cleanup
    end

    assert_equal "", out
    assert_equal "ActionMailer::ARSendmail#cleanup expired 1 emails from the queue\n", err
    assert_equal 2, Email.count(:conditions => {:failed => false})

    assert_equal [e1, e2], Email.all(:conditions => {:failed => false})
  end

  def test_cleanup_disabled
    e1 = Email.create :mail => 'body', :to => 'to', :from => 'from'
    e1.created_at = Time.now
    e2 = Email.create :mail => 'body', :to => 'to', :from => 'from'

    @sm.max_age = 0

    out, err = capture_io do
      @sm.cleanup
    end

    assert_equal '', out
    assert_equal 2, Email.count
  end

  def test_deliver
    pre_count = Email.count
    email = Email.create :mail => 'body', :to => 'to', :from => 'from'

    out, err = capture_io do
      @sm.deliver [email]
    end

    assert_equal 1, Net::SMTP.deliveries.length
    assert_equal ['body', 'from', 'to'], Net::SMTP.deliveries.first
    assert_equal pre_count + 1, Email.records.length
    assert_equal 0, Net::SMTP.reset_called, 'Reset connection on SyntaxError'

    assert_equal '', out
    assert_equal "ActionMailer::ARSendmail#deliver Delivering 1 emails through '' as ''\nActionMailer::ARSendmail#deliver sent email #{"%011d" % email.id.to_s} from from to to: \"queued\"\n", err
  end

  def test_deliver_not_called_when_no_emails
    sm = ActionMailer::ARSendmail.new({:Once => true})
    sm.expects(:deliver).never
    sm.run
  end

  def test_deliver_auth_error
    Net::SMTP.on_start do
      e = Net::SMTPAuthenticationError.new 'try again'
      e.set_backtrace %w[one two three]
      raise e
    end

    now = Time.now.to_i

    email = Email.create :mail => 'body', :to => 'to', :from => 'from'

    out, err = capture_io do
      @sm.deliver [email]
    end

    assert_equal 0, Net::SMTP.deliveries.length
    assert_equal 1, Email.records.length
    assert_equal 0, Email.records.first.last_send_attempt
    assert_equal 0, Net::SMTP.reset_called
    assert_equal 1, @sm.failed_auth_count
    assert_equal [60], @sm.slept
    assert_equal '', out
    assert_equal "ActionMailer::ARSendmail#deliver Delivering 1 emails through '' as ''\nActionMailer::ARSendmail#deliver authentication error, retrying: try again\n", err
  end

  def test_deliver_auth_error_recover
    email = Email.create :mail => 'body', :to => 'to', :from => 'from'
    @sm.failed_auth_count = 1

    out, err = capture_io do @sm.deliver [email] end

    assert_equal 0, @sm.failed_auth_count
    assert_equal 1, Net::SMTP.deliveries.length
  end

  def test_deliver_auth_error_twice
    Net::SMTP.on_start do
      e = Net::SMTPAuthenticationError.new 'try again'
      e.set_backtrace %w[one two three]
      raise e
    end

    @sm.failed_auth_count = 1

    out, err = capture_io do
      assert_raises Net::SMTPAuthenticationError do
        @sm.deliver []
      end
    end

    assert_equal 2, @sm.failed_auth_count
    assert_equal "ActionMailer::ARSendmail#deliver Delivering 0 emails through '' as ''\nActionMailer::ARSendmail#deliver authentication error, giving up: try again\n", err
  end

  def test_deliver_4xx_error
    Net::SMTP.on_send_message do
      e = Net::SMTPSyntaxError.new 'try again'
      e.set_backtrace %w[one two three]
      raise e
    end
  
    now = Time.now.to_i
  
    email = Email.create :mail => 'body', :to => 'to', :from => 'from'
  
    out, err = capture_io do
      @sm.deliver [email]
    end
  
    assert_equal 0, Net::SMTP.deliveries.length
    assert_equal 1, Email.records.length
    assert_operator now, :<=, Email.records.first.last_send_attempt
    assert_equal 1, Net::SMTP.reset_called, 'Reset connection on SyntaxError'
  
    assert_equal '', out
    assert_equal "ActionMailer::ARSendmail#deliver Delivering 1 emails through '' as ''\nActionMailer::ARSendmail#deliver error sending email #{email.id}: \"try again\"(Net::SMTPSyntaxError):\n\tone\n\ttwo\n\tthree\n", err
  end

  def test_deliver_5xx_error
    Net::SMTP.on_send_message do
      e = Net::SMTPFatalError.new 'unknown recipient'
      e.set_backtrace %w[one two three]
      raise e
    end

    now = Time.now.to_i

    email = Email.create :mail => 'body', :to => 'to', :from => 'from'

    out, err = capture_io do
      @sm.deliver [email]
    end

    assert_equal 0, Net::SMTP.deliveries.length
    assert_equal 1, Email.count(:conditions => {:failed => true})
    assert email.failed?
    assert_equal 1, Net::SMTP.reset_called, 'Reset connection on SyntaxError'

    assert_equal '', out
    assert_equal "ActionMailer::ARSendmail#deliver Delivering 1 emails through '' as ''\nActionMailer::ARSendmail#deliver 5xx error sending email #{email.id}, removing from queue: \"unknown recipient\"(Net::SMTPFatalError):\n\tone\n\ttwo\n\tthree\n", err
  end

  def test_deliver_errno_epipe
    Net::SMTP.on_send_message do
      raise Errno::EPIPE
    end

    now = Time.now.to_i

    email = Email.create :mail => 'body', :to => 'to', :from => 'from'

    out, err = capture_io do
      @sm.deliver [email]
    end

    assert_equal 0, Net::SMTP.deliveries.length
    assert_equal 1, Email.records.length
    assert_operator now, :>=, Email.records.first.last_send_attempt
    assert_equal 0, Net::SMTP.reset_called, 'Reset connection on SyntaxError'

    assert_equal '', out
    assert_equal "ActionMailer::ARSendmail#deliver Delivering 1 emails through '' as ''\n", err
  end

  def test_deliver_server_busy
    Net::SMTP.on_send_message do
      e = Net::SMTPServerBusy.new 'try again'
      e.set_backtrace %w[one two three]
      raise e
    end

    now = Time.now.to_i

    email = Email.create :mail => 'body', :to => 'to', :from => 'from'

    out, err = capture_io do
      @sm.deliver [email]
    end

    assert_equal 0, Net::SMTP.deliveries.length
    assert_equal 1, Email.records.length
    assert_operator now, :>=, Email.records.first.last_send_attempt
    assert_equal 0, Net::SMTP.reset_called, 'Reset connection on SyntaxError'
    assert_equal [60], @sm.slept

    assert_equal '', out
    assert_equal "ActionMailer::ARSendmail#deliver Delivering 1 emails through '' as ''\nActionMailer::ARSendmail#deliver server too busy, sleeping 60 seconds\n", err
  end

  def test_deliver_syntax_error
    Net::SMTP.on_send_message do
      Net::SMTP.on_send_message # clear
      e = Net::SMTPSyntaxError.new 'blah blah blah'
      e.set_backtrace %w[one two three]
      raise e
    end

    now = Time.now.to_i

    email1 = Email.create :mail => 'body', :to => 'to', :from => 'from'
    email2 = Email.create :mail => 'body2', :to => 'to2', :from => 'from'

    out, err = capture_io do
      @sm.deliver [email1, email2]
    end

    assert_equal 1, Net::SMTP.deliveries.length, 'delivery count'
    assert_equal 1, Net::SMTP.reset_called, 'Reset connection on SyntaxError'
    assert_operator now, :<=, Email.first.last_send_attempt

    assert_equal '', out
    assert_equal "ActionMailer::ARSendmail#deliver Delivering 2 emails through '' as ''\nActionMailer::ARSendmail#deliver error sending email #{email1.id}: \"blah blah blah\"(Net::SMTPSyntaxError):\n\tone\n\ttwo\n\tthree\nActionMailer::ARSendmail#deliver sent email #{"%011d" % email2.id} from from to to2: \"queued\"\n", err
  end

  def test_deliver_timeout
    Net::SMTP.on_send_message do
      e = Timeout::Error.new 'timed out'
      e.set_backtrace %w[one two three]
      raise e
    end

    now = Time.now.to_i

    email = Email.create :mail => 'body', :to => 'to', :from => 'from'

    out, err = capture_io do
      @sm.deliver [email]
    end

    assert_equal 0, Net::SMTP.deliveries.length
    assert_equal 1, Email.records.length
    assert_operator now, :>=, Email.records.first.last_send_attempt
    assert_equal 1, Net::SMTP.reset_called, 'Reset connection on Timeout'

    assert_equal '', out
    assert_equal "ActionMailer::ARSendmail#deliver Delivering 1 emails through '' as ''\nActionMailer::ARSendmail#deliver error sending email #{email.id}: \"timed out\"(Timeout::Error):\n\tone\n\ttwo\n\tthree\n", err
  end

  def test_do_exit
    out, err = capture_io do
      assert_raises SystemExit do
        @sm.do_exit
      end
    end

    assert_equal '', out
    assert_equal "ActionMailer::ARSendmail#deliver caught signal, shutting down\n", err
  end

  def test_log
    out, err = capture_io do
      @sm.log 'hi'
    end

    assert_equal "hi\n", err
  end

  def test_find_emails
    email_data = [
      { :mail => 'body0', :to => 'recip@h1.example.com', :from => 'nobody'},
      { :mail => 'body1', :to => 'recip@h1.example.com', :from => 'nobody'},
      { :mail => 'body2', :to => 'recip@h2.example.com', :from => 'nobody'},
    ]

    emails = email_data.map do |email_data| Email.create email_data end

    tried = Email.create :mail => 'body3', :to => 'recip@h3.example.com', :from => 'nobody', :last_send_attempt => (Time.now.to_i - 258)

    found_emails = []

    out, err = capture_io do
      found_emails = @sm.find_emails
    end
    
    assert_equal emails, found_emails

    assert_equal '', out
    assert_equal "ActionMailer::ARSendmail#deliver found 3 emails to send\n", err
  end

  def test_smtp_settings
    ActionMailer::Base.server_settings[:address] = 'localhost'

    assert_equal 'localhost', @sm.smtp_settings[:address]
  end

end
