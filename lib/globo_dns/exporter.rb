require File.expand_path('../../../config/environment', __FILE__)

module GloboDns
class Exporter
    include GloboDns::Config
    include GloboDns::Util

    CONFIG_START_TAG = '### BEGIN GloboDns ###'
    CONFIG_END_TAG   = '### END GloboDns ###'

    def export_all(named_conf_content, options = {})
        @options = options
        @logger  = @options.delete(:logger) || Rails.logger

        Domain.connection.execute "LOCK TABLE #{Domain.table_name} READ, #{Record.table_name} READ";

        #--- get last commit timestamp and the export/current timestamp
        Dir.chdir(File.join(BIND_CHROOT_DIR, BIND_CONFIG_DIR))
        @last_commit_date = Time.at(exec('git last commit date', Binaries::GIT, 'log', '-1', '--format="%ct"').to_i)
        @export_timestamp = Time.now.i

        Dir.mktmpdir do |tmp_dir|
            FileUtils.cp_r(File.join(BIND_CHROOT_DIR, BIND_CONFIG_DIR), tmp_dir, :preserve => true)

            #--- main configuration file ---
            if named_conf_content.present?
                export_named_conf(named_conf_content, tmp_dir)
            end

            #--- views
            File.open(File.join(tmp_dir, VIEWS_FILE), 'w') do |file|
            end

            #--- regular zone records
            File.open(File.join(tmp_dir, ZONES_FILE), 'w') do |file|
                Domain.master.each do |domain|
                    file.puts domain.to_bind9_conf
                end
            end

            # Dir.mkdir(File.join(tmp_dir, ZONES_DIR))
            Domain.master.each do |domain|
                if domain.updated_since(@last_commit_date)
                    export_domain(domain, tmp_dir)
                else
                    FileUtils.touch(File.join(tmp_dir, zonefile_path))
                end
            end

            #--- then, reverse zone records
            File.open(File.join(tmp_dir, REVERSE_FILE), 'w') do |file|
                Domain.reverse.each do |domain|
                    file.puts domain.to_bind9_conf
                end
            end

            # Dir.mkdir(File.join(tmp_dir, REVERSE_DIR))
            Domain.reverse.updated_since().each do |domain|
                if domain.updated_since(@last_commit_date)
                    export_domain(domain, tmp_dir)
                else
                    FileUtils.touch(File.join(tmp_dir, zonefile_path))
                end
            end

            #--- and, finally, the slaves + stubs + forwards
            File.open(File.join(tmp_dir, SLAVES_FILE), 'w') do |file|
                Domain.slave.each do |domain|
                    file.puts domain.to_bind9_conf
                end
            end

            #--- remove files that older than the export timestamp; these are the
            #    zonefiles from domains that have been removed from the database
            #    (otherwise they'd have been regenerated or 'touched')
            remove_untouched_zonefiles(File.join(tmp_dir, ZONES_DIR),   @export_timestamp)
            remove_untouched_zonefiles(File.join(tmp_dir, REVERSE_DIR), @export_timestamp)

            #--- sync generated files on the tmp dir to the one monitored by bind
            sync_and_commit(tmp_dir)

            #--- test the changes by parsing the git commit log
            test_changes if @options[:test_changes]
        end
    ensure
        Domain.connection.execute 'UNLOCK TABLES';
    end
    
    private

    def export_named_conf(content, tmp_dir)
        File.open(File.join(tmp_dir, NAMED_CONF_FILE), 'w') do |file|
            file.puts content
            file.puts CONFIG_START_TAG
            file.puts '# this block is auto generated; do not edit'
            file.puts
            file.puts "include \"#{File.join(BIND_CONFIG_DIR, VIEWS_FILE)}\";"
            file.puts "include \"#{File.join(BIND_CONFIG_DIR, ZONES_FILE)}\";"
            file.puts "include \"#{File.join(BIND_CONFIG_DIR, SLAVES_FILE)}\";"
            file.puts "include \"#{File.join(BIND_CONFIG_DIR, REVERSE_FILE)}\";"
            file.puts
            file.puts CONFIG_END_TAG
        end
    end

    def export_domain(domain, tmp_dir)
        @logger.info "[GloboDns::exporter] generating file \"#{domain.zonefile_path}\""
        format = build_record_format(domain)
        File.open(File.join(tmp_dir, domain.zonefile_path), 'w') do |file|
            export_records(domain.records.order("FIELD(type, #{RECORD_ORDER.map{|x| "'#{x}'"}.join(', ')}), name ASC"), file, format)
        end
    end

    def export_records(records, file, format)
        return if records.nil?

        records = Array[records]                if records.is_a?(Record)
        records = records.includes(:domain).all if records.is_a?(ActiveRecord::Relation)

        records.collect do |record|
            file.print record.to_zonefile(format)
        end
    end

    def build_record_format(domain)
        sizes = domain.records.select('MAX(LENGTH(name)) AS name, LENGTH(MAX(ttl)) AS ttl, MAX(LENGTH(type)) AS mtype, LENGTH(MAX(prio)) AS prio').first
        "%-#{sizes.name}s %-#{sizes.ttl}d IN %-#{sizes.mtype}s %-#{sizes.prio}s %s\n"
    end

    def remove_untouched_zonefiles(dir, timestamp)
        Dir.glob(File.join(dir, 'db.*')).each do |file|
            if File.mtime(file) < timestamp
                @logger.info "[INFO] removing untouched zonefile \"#{file}\""
                File.rm(file)
            end
        end
    end

    def sync_and_commit(tmp_dir)
        #--- sync to Bind9's data dir
        rsync_output = exec('rsync', Binaries::RSYNC,
                                     '--checksum',
                                     '--archive',
                                     '--delete',
                                     '--verbose',
                                     '--omit-dir-times',
                                     '--no-group',
                                     '--no-perms',
                                     "--include=#{NAMED_CONF_FILE}",
                                     "--include=#{VIEWS_FILE}",
                                     "--include=#{ZONES_FILE}",
                                     "--include=#{SLAVES_FILE}",
                                     "--include=#{ZONES_DIR}/",
                                     "--include=#{ZONES_DIR}/*",
                                     "--include=#{REVERSE_DIR}/",
                                     "--include=#{REVERSE_DIR}/*",
                                     '--exclude=*',
                                     File.join(tmp_dir, ''),
                                     File.join(BIND_CHROOT_DIR, BIND_CONFIG_DIR, ''))
        @logger.debug "[GloboDns::Exporter][DEBUG] rsync:\n#{rsync_output}"

        #--- commit changes to the git repository
        Dir.chdir(File.join(BIND_CHROOT_DIR, BIND_CONFIG_DIR))

        # save the current HEAD and dump it to the log
        orig_head = (exec('git rev-parse', Binaries::GIT, 'rev-parse', 'HEAD')).chomp
        @logger.info "[GloboDns::Exporter][INFO] git repository ORIG_HEAD: #{orig_head}"

        begin
            exec('git add', Binaries::GIT, 'add', '-A')

            git_status_output = exec('git commit', Binaries::GIT, 'status')
            unless git_status_output =~ /nothing to commit \(working directory clean\)/
                commit_output = exec('git commit', Binaries::GIT, 'commit', '-m', '"[GloboDns::exporter]"')
                @logger.info "[GloboDns::Exporter][INFO] changes committed:\n#{commit_output}"

                # setup file handle to read and report error messages from bind's 'error log'
                if err_log = File.open(BIND_ERROR_LOG, 'r') rescue nil
                    err_log.seek(err_log.size)
                else
                    @logger.warn "[GloboDns::Exporter][WARN] unable to open bind's error log file \"#{BIND_ERROR_LOG}\""
                end

                reload_output = reload_bind_conf
                @logger.info "[GloboDns::Exporter][INFO] bind configuration reloaded:\n#{reload_output}"
                sleep 5

                # after reloading, read new entries from error log
                if err_log
                    entries = err_log.gets(nil)
                    err_log.close
                end

                test_changes if @options[:test_changes] && @options[:abort_on_test_failure]
            end
        rescue Exception => e
            @logger.error e.to_s + e.backtrace.join("\n")
            STDERR.puts   e, e.backtrace
            if @options[:reset_repository_on_failure]
                exec('git reset', Binaries::GIT,  'reset', '--hard', orig_head) # try to rollback changes
                reload_bind_conf
            end
            exit 1
        end
    end

    def reload_bind_conf
        exec('rndc reload', Binaries::RNDC, '-c', RNDC_CONFIG_FILE, '-y', RNDC_KEY, 'reload')
    end

    def test_changes
        # TODO: move the tests inside the 'begin; rescue;' block above, to
        # ensure we revert the changes when any test fails; or make this
        # optional, using a key in the config file
        tester = GloboDns::Tester.new
        tester.setup
        tester.run
    end

end # Exporter
end # GloboDns
