#
# Copyright:: Copyright (c) 2014 Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'fileutils'
require 'tmpdir'
require 'zlib'

require 'archive/tar/minitar'

require 'chef/cookbook/chefignore'

require 'chef-dk/service_exceptions'
require 'chef-dk/policyfile_lock'
require 'chef-dk/policyfile/storage_config'

module ChefDK
  module PolicyfileServices

    class ExportRepo

      # Policy groups provide namespaces for policies so that a Chef Server can
      # have multiple active iterations of a policy at once, but we don't need
      # this when serving a single exported policy via Chef Zero, so hardcode
      # it to a "well known" value:
      POLICY_GROUP = 'local'.freeze

      include Policyfile::StorageConfigDelegation

      attr_reader :storage_config
      attr_reader :root_dir
      attr_reader :export_dir

      def initialize(policyfile: nil, export_dir: nil, root_dir: nil, archive: false, force: false)
        @root_dir = root_dir
        @export_dir = File.expand_path(export_dir)
        @archive = archive
        @force_export = force

        @policy_data = nil
        @policyfile_lock = nil

        policyfile_rel_path = policyfile || "Policyfile.rb"
        policyfile_full_path = File.expand_path(policyfile_rel_path, root_dir)
        @storage_config = Policyfile::StorageConfig.new.use_policyfile(policyfile_full_path)

        @staging_dir = nil
      end

      def archive?
        @archive
      end

      def policy_name
        policyfile_lock.name
      end

      def run
        assert_lockfile_exists!
        assert_export_dir_clean!

        validate_lockfile
        write_updated_lockfile
        export
      end

      def policy_data
        @policy_data ||= FFI_Yajl::Parser.parse(IO.read(policyfile_lock_expanded_path))
      rescue => error
        raise PolicyfileExportRepoError.new("Error reading lockfile #{policyfile_lock_expanded_path}", error)
      end

      def policyfile_lock
        @policyfile_lock || validate_lockfile
      end

      def archive_file_location
        return nil unless archive?
        filename = "#{policyfile_lock.name}-#{policyfile_lock.revision_id}.tgz"
        File.join(export_dir, filename)
      end

      def export
        with_staging_dir do
          create_repo_structure
          copy_cookbooks
          create_policyfile_data_item
          copy_policyfile_lock
          create_client_rb
          if archive?
            create_archive
          else
            mv_staged_repo
          end
        end
      rescue => error
        msg = "Failed to export policy (in #{policyfile_filename}) to #{export_dir}"
        raise PolicyfileExportRepoError.new(msg, error)
      end

      private

      def with_staging_dir
        p = Process.pid
        t = Time.new.utc.strftime("%Y%m%d%H%M%S")
        Dir.mktmpdir("chefdk-export-#{p}-#{t}") do |d|
          begin
            @staging_dir = d
            yield
          ensure
            @staging_dir = nil
          end
        end
      end

      def create_archive
        Zlib::GzipWriter.open(archive_file_location) do |gz_file|
          Dir.chdir(staging_dir) do
            Archive::Tar::Minitar.pack(".", gz_file)
          end
        end
      end

      def staging_dir
        @staging_dir
      end

      def create_repo_structure
        FileUtils.mkdir_p(export_dir)
        FileUtils.mkdir_p(cookbooks_staging_dir)
        FileUtils.mkdir_p(policyfiles_data_bag_staging_dir)
      end

      def copy_cookbooks
        policyfile_lock.cookbook_locks.each do |name, lock|
          copy_cookbook(lock)
        end
      end

      def copy_cookbook(lock)
        dirname = "#{lock.name}-#{lock.dotted_decimal_identifier}"
        export_path = File.join(staging_dir, "cookbooks", dirname)
        metadata_rb_path = File.join(export_path, "metadata.rb")
        FileUtils.mkdir(export_path) if not File.directory?(export_path)
        FileUtils.cp_r(cookbook_files_to_copy(lock.cookbook_path), export_path)
        FileUtils.rm_f(metadata_rb_path)
        metadata = lock.cookbook_version.metadata
        metadata.version(lock.dotted_decimal_identifier)

        metadata_json_path = File.join(export_path, "metadata.json")

        File.open(metadata_json_path, "wb+") do |f|
          f.print(FFI_Yajl::Encoder.encode(metadata.to_hash, pretty: true ))
        end
      end

      def cookbook_files_to_copy(cookbook_path)
        chefignore_file = File.join(cookbook_path, 'chefignore')
        chefignore = Chef::Cookbook::Chefignore.new(chefignore_file)
        Dir.glob(File.join(cookbook_path, '*')).
          reject{ |f| chefignore.ignored?(File.basename(f)) }
      end

      def create_policyfile_data_item
        lock_data = policyfile_lock.to_lock.dup

        lock_data["id"] = policy_id

        data_item = {
          "id" => policy_id,
          "name" => "data_bag_item_policyfiles_#{policy_id}",
          "data_bag" => "policyfiles",
          "raw_data" => lock_data,
          # we'd prefer to leave this out, but the "compatibility mode"
          # implementation in chef-client relies on magical class inflation
          "json_class" => "Chef::DataBagItem"
        }

        File.open(item_path, "wb+") do |f|
          f.print(FFI_Yajl::Encoder.encode(data_item, pretty: true ))
        end
      end

      def copy_policyfile_lock
        File.open(lockfile_staging_path, "wb+") do |f|
          f.print(FFI_Yajl::Encoder.encode(policyfile_lock.to_lock, pretty: true ))
        end
      end

      def create_client_rb
        File.open(client_rb_staging_path, "wb+") do |f|
          f.print( <<-CONFIG )
### Chef Client Configuration ###
# The settings in this file will configure chef to apply the exported policy in
# this directory. To use it, run:
#
# chef-client -c client.rb -z
#

use_policyfile true

# compatibility mode settings are used because chef-zero doesn't yet support
# native mode:
deployment_group '#{policy_name}-local'
versioned_cookbooks true
policy_document_native_api false

CONFIG
        end
      end

      def mv_staged_repo
        # If we got here, either these dirs are empty/don't exist or force is
        # set to true.
        FileUtils.rm_rf(cookbooks_dir)
        FileUtils.rm_rf(policyfiles_data_bag_dir)

        FileUtils.mv(cookbooks_staging_dir, export_dir)
        FileUtils.mkdir_p(export_data_bag_dir)
        FileUtils.mv(policyfiles_data_bag_staging_dir, export_data_bag_dir)
        FileUtils.mv(lockfile_staging_path, export_dir)
        FileUtils.mv(client_rb_staging_path, export_dir)
      end

      def validate_lockfile
        return @policyfile_lock if @policyfile_lock
        @policyfile_lock = ChefDK::PolicyfileLock.new(storage_config).build_from_lock_data(policy_data)
        # TODO: enumerate any cookbook that have been updated
        @policyfile_lock.validate_cookbooks!
        @policyfile_lock
      rescue PolicyfileExportRepoError
        raise
      rescue => error
        raise PolicyfileExportRepoError.new("Invalid lockfile data", error)
      end

      def write_updated_lockfile
        File.open(policyfile_lock_expanded_path, "wb+") do |f|
          f.print(FFI_Yajl::Encoder.encode(policyfile_lock.to_lock, pretty: true ))
        end
      end

      def assert_lockfile_exists!
        unless File.exist?(policyfile_lock_expanded_path)
          raise LockfileNotFound, "No lockfile at #{policyfile_lock_expanded_path} - you need to run `install` before `push`"
        end
      end

      def assert_export_dir_clean!
        if !force_export? && !conflicting_fs_entries.empty? && !archive?
          msg = "Export dir (#{export_dir}) not clean. Refusing to export. (Conflicting files: #{conflicting_fs_entries.join(', ')})"
          raise ExportDirNotEmpty, msg
        end
      end

      def force_export?
        @force_export
      end

      def conflicting_fs_entries
        Dir.glob(File.join(cookbooks_dir, "*")) +
          Dir.glob(File.join(policyfiles_data_bag_dir, "*")) +
          Dir.glob(File.join(export_dir, "Policyfile.lock.json"))
      end

      def cookbooks_dir
        File.join(export_dir, "cookbooks")
      end

      def export_data_bag_dir
        File.join(export_dir, "data_bags")
      end

      def policyfiles_data_bag_dir
        File.join(export_data_bag_dir, "policyfiles")
      end

      def policy_id
        "#{policyfile_lock.name}-#{POLICY_GROUP}"
      end

      def item_path
        File.join(staging_dir, "data_bags", "policyfiles", "#{policy_id}.json")
      end

      def cookbooks_staging_dir
        File.join(staging_dir, "cookbooks")
      end

      def policyfiles_data_bag_staging_dir
        File.join(staging_dir, "data_bags", "policyfiles")
      end

      def lockfile_staging_path
        File.join(staging_dir, "Policyfile.lock.json")
      end

      def client_rb_staging_path
        File.join(staging_dir, "client.rb")
      end

    end

  end
end

