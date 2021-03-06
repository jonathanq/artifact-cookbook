class Chef
  module Artifact
    DATA_BAG = "artifact".freeze
    WILDCARD_DATABAG_ITEM = "_wildcard".freeze
    DATA_BAG_NEXUS = 'nexus'.freeze
    DATA_BAG_AWS = 'aws'.freeze

    module File

      # Returns true if the given file is a symlink.
      # 
      # @param  path [String] the path to the file to test
      # 
      # @return [Boolean]
      def symlink?(path)
        if windows?
          require 'chef/win32/file'
          return Chef::ReservedNames::Win32::File.symlink?(path)
        end
        ::File.symlink?(path)        
      end

      # Returns the value of the readlink method.
      # 
      # @param  path [String] the path to a symlink
      # 
      # @return [String] the path that the symlink points to
      def readlink(path)
        if windows?
          require 'chef/win32/file'
          return Chef::ReservedNames::Win32::File.readlink(path)
        end
        ::File.readlink(path)
      end

      # Generates a command to execute that either uses the Unix cp
      # command or the Windows copy command. 
      #
      # @param  source [String] the file to copy
      # @param  destination [String] the path to copy the source to
      # 
      # @return [String] a useable command to copy a file
      def copy_command_for(source, destination)
        if windows?
          %Q{copy "#{source}" "#{destination}"}.gsub(::File::SEPARATOR, ::File::ALT_SEPARATOR)
        else
         "cp -r #{source} #{destination}"
        end
      end

      # @return [Fixnum or nil]
      def windows?
        Chef::Platform.windows?
      end
    end

    class << self
      include Chef::Artifact::File

      # Loads the encrypted data bag item and returns credentials
      # for the environment or for a default key.
      #
      # @param  node [Chef::Node] the Chef node
      # @param  source [String] the deployment source to load configuration for
      # 
      # @return [Chef::DataBagItem] the data bag item
      def data_bag_config_for(node, source)
        data_bag_item = if Chef::Config[:solo]
          Chef::DataBagItem.load(DATA_BAG, WILDCARD_DATABAG_ITEM) rescue {}
        else
          encrypted_data_bag_for(node, DATA_BAG)
        end

        # support new format
        return data_bag_item[source] if data_bag_item.has_key?(source)

        # backwards compatible for old data bag formats using nexus
        return data_bag_item if DATA_BAG_NEXUS == source

        # no config found for source
        {}
      end

      # Uses the provided parameters to make a call to the data bag
      # configured Nexus server to have the server tell us what the
      # actual version number is when 'latest' is given.
      # 
      # @param  node [Chef::Node] the node
      # @param  artifact_location [String] a colon-separated Maven identifier string that represents the artifact
      # @param  ssl_verify [Boolean] a boolean to pass through to the NexusCli::RemoteFactory#create method. This
      #   is a TERRIBLE IDEA and you should never want to set this to false!
      # 
      # @example
      #   Chef::Artifact.get_actual_version(node, "com.myartifact:my-artifact:latest:tgz") => "2.0.5"
      #   Chef::Artifact.get_actual_version(node, "com.myartifact:my-artifact:1.0.1:tgz")  => "1.0.1"
      # 
      # @return [String] the version number that latest resolves to or the passed in value
      def get_actual_version(node, artifact_location, ssl_verify=true)
        version = artifact_location.split(':')[2]
        if latest?(version)
          require 'nexus_cli'
          require 'rexml/document'
          config = data_bag_config_for(node, DATA_BAG_NEXUS)
          if config.empty?
            raise DataBagNotFound.new(DATA_BAG_NEXUS)
          end
          remote = NexusCli::RemoteFactory.create(config, ssl_verify)
          REXML::Document.new(remote.get_artifact_info(artifact_location)).elements["//version"].text
        else
          version
        end
      end

      # Downloads a file to disk from the configured Nexus server.
      # 
      # @param  node [Chef::Node] the node
      # @param  source [String] a colon-separated Maven identified string that represents the artifact
      # @param  destination_dir [String] a path to download the artifact to
      #
      # @option options [Boolean] :ssl_verify
      #   a boolean to pass through to the NexusCli::RemoteFactory#create method indicated whether
      #   ssl methods should or should not be verified.
      # 
      # @return [Hash] writes a file to disk and returns a Hash with
      # information about that file. See NexusCli::ArtifactActions#pull_artifact.
      def retrieve_from_nexus(node, source, destination_dir, options = {})
        require 'nexus_cli'
        config = data_bag_config_for(node, DATA_BAG_NEXUS)
        if config.empty?
          raise DataBagNotFound.new(DATA_BAG_NEXUS)
        end
        remote = NexusCli::RemoteFactory.create(config, options[:ssl_verify])
        remote.pull_artifact(source, destination_dir)
      end

      # Downloads a file to disk from an Amazon S3 bucket
      #
      # @param  node [Chef::Node] the node
      # @param  source_file [String] a s3 url that represents the artifact in the form: s3://<endpoint>/<bucket>/<object-path>
      # @param  destination_file [String] a path to download the artifact to
      #
      def retrieve_from_s3(node, source_file, destination_file)
        begin
          require 'aws-sdk'
          config = data_bag_config_for(node, DATA_BAG_AWS)
          s3_region, bucket_name, object_name = parse_s3_url(source_file)

          s3_client = configure_s3_client(config, s3_region)
          object = get_s3_object(s3_client, bucket_name, object_name)

          Chef::Log.debug("Downloading #{object_name} from S3 bucket #{bucket_name}")
          ::File.open(destination_file, 'w') do |file|
            object.read do |chunk|
              file.write(chunk)
            end
            Chef::Log.debug("File #{destination_file} is #{file.size} bytes on disk")
          end
        rescue URI::InvalidURIError
          Chef::Log.warn("Expected an S3 URL but found #{source_file}")
          raise
        end
      end

      # Create an AWS::S3 client that is configured with AWS Credentials (if provided in the data_bag) and the correct
      # AWS region for the bucket being accessed.  If no AWS credentials are provided in the data_bag, it will assume
      # the machine has an IAM Instance Profile available to get credentials from.
      #
      # @example
      #   s3_client = Chef::Artifact.configure_s3_client({:access_key_id =>'access-key', :secret_access_key => 'secret-key'}, 'us-west-2')
      #
      # @param  config [Hash] Data bag configuration to load credentials from
      # @param  s3_region [String] S3 Region to connect to
      #
      # @return [AWS::S3] An S3 client object that has been configured with credentials (if provided) for the correct region
      def configure_s3_client(config, s3_region)
        unless config.empty?
          AWS.config(:access_key_id => config['access_key_id'], :secret_access_key => config['secret_access_key'])
        end
        AWS::S3.new(:region => s3_region)
      end

      # Parse a source url to retrieve the specific parts required to interact with the object on S3.  This method
      # will also convert the s3 endpoint in the URL to the correct AWS Region.
      #
      # @example
      #   s3_region, bucket_name, object_name = Chef::Artifact.parse_s3_url('s3://s3.amazonaws.com/my-bucket/my-file.txt')
      #
      # @param  source_url [String] Source url to parse
      #
      # @return [Array] An array containing the S3 Region, Bucket Name and Object Name
      def parse_s3_url(source_url)
        protocol, s3_endpoint, bucket_and_object = URI.split(source_url).compact
        s3_region = 'us-east-1'  # default region
        AWS.regions.each do |region|
          s3_region = region.name if region.s3.client.endpoint == s3_endpoint
        end
        path_parts = bucket_and_object[1..-1].split('/')
        bucket_name = path_parts[0]
        object_name = path_parts[1..-1].join('/')
        [s3_region, bucket_name, object_name]
      end

      # Given an s3_client, bucket name and object name - fetches the object from S3
      #
      # @example
      #   object = Chef::Artifact.get_s3_object(s3_client, 'my-bucket', 'my-file.txt')
      #
      # @param  s3_client [AWS::S3]
      # @param  bucket_name [String] Name of the S3 bucket
      # @param  object_name [String] Name of the S3 object
      #
      # @return [AWS::S3::S3Object] An S3 Object
      def get_s3_object(s3_client, bucket_name, object_name)
        bucket = s3_client.buckets[bucket_name]
        raise S3BucketNotFoundError.new(bucket_name) unless bucket.exists?

        object = bucket.objects[object_name]
        raise S3ArtifactNotFoundError.new(bucket_name, object_name) unless object.exists?
        object
      end

      # Generates a URL that hits the Nexus redirect endpoint which will
      # result in an artifact being downloaded.
      #
      # @example
      #   Chef::Artifact.artifact_download_url_for(node, "com.myartifact:my-artifact:1.0.1:tgz")
      #     => "http://my-nexus:8081/nexus/service/local/artifact/maven/redirect?g=com.myartifact&a=my-artifact&v=1.0.1&e=tgz&r=my_repo"
      #
      # @param  node [Chef::Node]
      # @param  source [String] colon separated Nexus location
      # 
      # @return [String] a URL that can be used to retrieve an artifact
      def artifact_download_url_for(node, source, ssl_verify=true)
        # TODO: Move this method into the nexus-cli
        config = data_bag_config_for(node, DATA_BAG_NEXUS)
        group_id, artifact_id, version, extension = source.split(':')
        query_string = "g=#{group_id}&a=#{artifact_id}&v=#{version}&e=#{extension}&r=#{config['repository']}"
        uri_for_url = URI(config['url'])
        builder = uri_for_url.scheme =~ /https/ ? URI::HTTPS : URI::HTTP
        builder_options = {
          host: uri_for_url.host, 
          port: uri_for_url.port, 
          path: '/nexus/service/local/artifact/maven/redirect', 
          query: query_string
        }
        builder_options[:userinfo] = "#{config['username']}:#{config['password']}" unless anonymous_enabled?(node, ssl_verify)

        builder.build(builder_options).to_s
      end

      # Makes a call to Nexus and parses the returned XML to return
      # the Nexus Server's stored SHA1 checksum for the given artifact.
      #
      # @param  node [Chef::Node] the node
      # @param  artifact_location [String] a colon-separated Maven identifier that represents the artifact
      # @param  ssl_verify=true [Boolean] whether or not ssl methods will be verified
      #
      # @return [String] the SHA1 entry for the artifact
      def get_artifact_sha(node, artifact_location, ssl_verify=true)
        require 'nexus_cli'
        require 'rexml/document'
        config = data_bag_config_for(node, DATA_BAG_NEXUS)
        remote = NexusCli::RemoteFactory.create(config, ssl_verify)
        REXML::Document.new(remote.get_artifact_info(artifact_location)).elements["//sha1"].text
      end

      # Checks the nexus server to see if the anonymous user is enabled
      #
      # @param node [Chef::Node] the node
      # @param  ssl_verify=true [Boolean] whether or not ssl methods will be verified
      #
      # @return [Boolean]
      def anonymous_enabled?(node, ssl_verify=true)
        # TODO extract remote
        require 'nexus_cli'
        config = data_bag_config_for(node, DATA_BAG_NEXUS)
        remote = NexusCli::RemoteFactory.create(config, ssl_verify)
        remote.get_user('anonymous')['status'] == 'enabled'
      end

      # Returns true when the artifact is believed to be from a
      # Nexus source.
      #
      # @param  location [String] the artifact_location
      # 
      # @return [Boolean] true when the location is a colon-separated value
      def from_nexus?(location)
        !from_http?(location) && location.split(":").length > 2
      end

      # Returns true when the artifact is believed to be from an
      # S3 bucket.
      #
      # @param  location [String] the artifact_location
      #
      # @return [Boolean] true when the location matches s3
      def from_s3?(location)
        location_of_type(location, 's3')
      end

      # Returns true when the artifact is believed to be from an
      # http source.
      # 
      # @param  location [String] the artifact_location
      # 
      # @return [Boolean] true when the location matches http or https.
      def from_http?(location)
        location_of_type(location, %w(http https))
      end

      # Returns true when the location URI scheme matches the type
      #
      # @param  location [String] the location URI to check
      # @param  uri_type [Array] list of URI types to check
      #
      # @return [Boolean] true when the location matches the given URI type
      def location_of_type(location, uri_type)
        not (location =~ URI::regexp(uri_type)).nil?
      end

      # Convenience method for determining whether a String is "latest"
      #
      # @param  version [String] the version of the configured artifact to check
      #
      # @return [Boolean] true when version matches (case-insensitive) "latest"
      def latest?(version)
        version.casecmp("latest") == 0
      end

      # Returns the currently deployed version of an artifact given that artifacts
      # installation directory by reading what directory the 'current' symlink
      # points to.
      # 
      # @param  deploy_to_dir [String] the directory where an artifact is installed
      # 
      # @example
      #   Chef::Artifact.get_current_deployed_version("/opt/my_deploy_dir") => "2.0.65"
      # 
      # @return [String] the currently deployed version of the given artifact
      def get_current_deployed_version(deploy_to_dir)

        current_dir = ::File.join(deploy_to_dir, "current")
        if ::File.exists?(current_dir)
          ::File.basename(readlink(current_dir))
        end
      end

      # Looks for the given data bag in the cache and if not found, will load a
      # data bag item named for the chef_environment, '_wildcard', or the old 
      # 'nexus' value.
      #
      # @param  node [Chef::Node] the node
      # @param  data_bag [String] the data bag to load
      # 
      # @return [Chef::Mash] the data bag item in Mash form
      def encrypted_data_bag_for(node, data_bag)
        @encrypted_data_bags = {} unless @encrypted_data_bags

        if encrypted_data_bags[data_bag]
          return get_from_data_bags_cache(data_bag)
        else
          data_bag_item = encrypted_data_bag_item(data_bag, node.chef_environment)
          data_bag_item ||= encrypted_data_bag_item(data_bag, WILDCARD_DATABAG_ITEM)
          data_bag_item ||= encrypted_data_bag_item(data_bag, "nexus")
          data_bag_item ||= {}
          @encrypted_data_bags[data_bag] = data_bag_item
          return data_bag_item
        end
      end

      # @return [Hash]
      def encrypted_data_bags
        @encrypted_data_bags
      end

      # Loads an entry from the encrypted_data_bags class variable.
      #
      # @param data_bag [String] the data bag to find
      # 
      # @return [type] [description]
      def get_from_data_bags_cache(data_bag)
        encrypted_data_bags[data_bag]
      end

      # Loads an EncryptedDataBagItem from the Chef server and
      # turns it into a Chef::Mash, giving it indifferent access. Returns
      # nil when a data bag item is not found.
      #
      # @param  data_bag [String]
      # @param  data_bag_item [String]
      # 
      # @raise [Chef::Artifact::DataBagEncryptionError] when the data bag cannot be decrypted
      #   or transformed into a Mash for some reason (Chef 10 vs Chef 11 data bag changes).
      # 
      # @return [Chef::Mash]
      def encrypted_data_bag_item(data_bag, data_bag_item)
        Mash.from_hash(Chef::EncryptedDataBagItem.load(data_bag, data_bag_item).to_hash)
      rescue Net::HTTPServerException => e
        nil
      rescue NoMethodError
        raise DataBagEncryptionError.new
      end
    end
  end
end
