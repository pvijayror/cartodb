# encoding: utf-8

namespace :cartodb do
  desc "Adapt max_import_file_size according to disk quota"
  task :setup_max_import_file_size_based_on_disk_quota => :environment do
    mid_size = 500*1024*1024
    big_size = 1000*1024*1024
  
    User.all.each do |user|
      quota_in_mb = user.quota_in_bytes/1024/1024
      if quota_in_mb >= 450 && quota_in_mb < 1500
        user.max_import_file_size = mid_size
        user.save
        print "M"
      elsif quota_in_mb >= 1500
        user.max_import_file_size = big_size
        user.save
        print "B"
      else
        print "."
      end
    end
    puts "\n"
  end
  
  desc "Adapt max_import_table_row_count according to disk quota"
  task :setup_max_import_table_row_count_based_on_disk_quota => :environment do
    mid_count = 1000000
    big_count = 5000000
  
    User.all.each do |user|
      quota_in_mb = user.quota_in_bytes/1024/1024
      if quota_in_mb >= 50 && quota_in_mb < 1000
        user.max_import_table_row_count = mid_count
        user.save
        print "M"
      elsif quota_in_mb >= 1000
        user.max_import_table_row_count = big_count
        user.save
        print "B"
      else
        print "."
      end
    end
    puts "\n"
  end
  
  desc "Increase limits for twitter import users"
  task :increase_limits_for_twitter_import_users => :environment do
    file_size_quota = 1500*1024*1024
    row_count_quota = 5000000

    User.where(twitter_datasource_enabled: true).each do |user|
      # Only increase, don't decrease
      user.max_import_file_size = file_size_quota if file_size_quota > user.max_import_file_size
      user.max_import_table_row_count = row_count_quota if row_count_quota > user.max_import_table_row_count
      user.save
      puts "#{user.username}"
    end
  end
end
