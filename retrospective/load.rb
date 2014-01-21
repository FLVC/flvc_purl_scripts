%w(rexml/document net/http uri cgi).each { |f| require f }
#require 'ruby-debug'
#debugger
require 'yaml'
include REXML

# Configuration
config = YAML.load_file('/usr/local/islandora/flvc_purl_scripts/retrospective/config.yml')

PURLZ_ADDRESS  = config['purl_server']
PURLZ_USERNAME = config['purl_username']
PURLZ_PASSWORD = config['purl_password']

PURLZ_PORT = 80
ERROR_LOG = 'purl_errors.log' # File for recording failed operations
BETWEEN_REQUESTS = 0.0 # Time to sleep between requests, in seconds
DEBUGGING = false #leave false - see below


# Command-line
if ARGV.empty?
  puts "usage: #{$0} purls.tab [create|delete]"
  exit
end

#first parameter is input file
input_filename = ARGV[0]

#mode is 2nd param and used for switching cases
mode = (ARGV[1] == 'delete' ? :delete : :create)

@http = Net::HTTP.new(PURLZ_ADDRESS, PURLZ_PORT)

#not safe to use - may cause serious security hole
@http.set_debug_output STDERR if DEBUGGING


# Convenience function for escaping CGI params
def x(text); CGI.escape(text); end

# Log in and store authentication cookie for future use
def log_in
  @http.request_post(
    '/admin/login/login-submit.bsh',
    "id=#{x(PURLZ_USERNAME)}&passwd=#{x(PURLZ_PASSWORD)}"
  ) do |response|
    raise "PURLZ login failed" if response['location'].include?('failure')
    @session_key = response['set-cookie'][%r(session:([0-9A-F]+)), 1]
  end
end

def cookies
  {'Cookie' => 'NETKERNELSESSION=session:' + @session_key}
end

# Raises HTTPServerException unless response code is 200
def create_purl(id, target, maintainers, type)
  @http.request_post(
    '/admin/purl' + id,
    "target=#{x(target)}&maintainers=#{x(maintainers * ',')}&type=#{type}",
    cookies
  ).value
end

# Raises HTTPServerException unless response code is 200
def modify_purl(id, target, maintainers, type)
  @http.request_put(
    '/admin/purl' + id +
      "?target=#{x(target)}&maintainers=#{x(maintainers * ',')}&type=#{type}",
    '', # Put has no body
    {'Cookie' => 'NETKERNELSESSION=session:' + @session_key}
  ).value
end

# Raises HTTPServerException unless response code is 200
def delete_purl(id)
  @http.delete(
    '/admin/purl' + id,
    {'Cookie' => 'NETKERNELSESSION=session:' + @session_key}
  ).value
end

# Parses tab-separated stream and yields each PURL to the calling block
class File
  def each_purl
    until eof?
      id, type, maintainers, target = gets.chomp.split("\t")
	  #split list of maintainers and separate with comma
      maintainers = maintainers.split(',')
      yield id, type, maintainers, target
    end
  end
end


log_in

File.open(ERROR_LOG, 'a') do |error_log|
	#put time stamp to_string
  error_log.puts Time.new.to_s
	#open file
  File.open(input_filename) do |input|
    input.each_purl do |id, type, maintainers, target|
      puts id
	  puts "target=#{x(target)}&maintainers=#{x(maintainers * ',')}&type=#{type}"
      begin
        case mode
        when :create
          begin
            create_purl id, target, maintainers, type
            puts "  created"
          rescue Net::HTTPServerException => e
            # PURL already exists, so modify it instead
			xml = Net::HTTP.get_response(URI.parse('http://' + PURLZ_ADDRESS + '/admin/purl' + id)).body
			doc = REXML::Document.new(xml)

			begin
				maintainList = String.new #current list of maintainers

				doc.elements.each('purl/target/url') do |ele|
					
					#build list of maintainers from online resource
					doc.elements.each('purl/maintainers/uid') do |uid|
						maintainList << uid.text + "\n"
					end
					
					doc.elements.each('purl/maintainers/gid') do |gid|
						maintainList << gid.text + "\n"
					end 

					maintainList = maintainList.split
					maintainers.each { |x| x.strip! } #helps normalize by removing extra white-space
					
					maintainNew = Array.new #place holder for any new maintainers not found online
										
					maintainers.each do |x|
					  boolFound = false #initialize not found yet
					  maintainList.each do |y|
					    
						if x.casecmp( y ) == 0
						  boolFound = true #found
						end
					  end
					  if boolFound == false #maintainer not found
					    maintainNew << x
					  end
					end
									
					if maintainNew.length > 0 #if some new maintainers were found
					  maintainList.concat( maintainNew ) #add to list of online maintainers
					  maintainers = maintainList #redirect reference to new combined list
					end
					
					#if targets are the same AND there are no new maintainers
					if (ele.text .eql? target) && maintainNew.length == 0
						puts ".....target and maintainers are the same"
					else	#else we modify!
						modify_purl id, target, maintainers, type
						puts "  modified"
					end
				end
			end
          end
        when :delete
          delete_purl id
          puts "  deleted"
        end
      rescue Exception => e
        error_log.puts id
        error_log.puts '  ' + e.to_s
      end
      sleep BETWEEN_REQUESTS
    end
  end
end
