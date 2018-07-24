require 'logger'
require "zabbixapi"
require 'json'
require 'rubygems'
require 'net/https'
require 'date'
require 'getoptlong'
require 'yaml'
require 'ruby_dig'
puppet_hostnames = []
zabbix_hostnames = []
remove_hostnames = []
remove_hostids   = []
servers = {
  'Prod_Facter_DC'    => {},
  'NonProd_Facter_DC' => {},
  'Other_DC'          => {},
}
server = ["<nonprod_puppet>", "<prod_puppet>"]
port = '8080'
endpoint = '/pdb/query/v4/facts'
a_hostid = []
logger = Logger.new('/var/log/zabbix_manage_hosts.log')

zbx = ZabbixApi.connect(
  :url => 'http://localhost/zabbix/api_jsonrpc.php',
  :user => '<username>',
  :password => '<password>',
)

# create server list from puppet db facts datacenter
server.each do |servername|
  datacenteruri = URI("http://#{servername}:#{port}#{endpoint}/datacenter")
  http = Net::HTTP.new(datacenteruri.host, datacenteruri.port)
  request = Net::HTTP::Get.new(datacenteruri)
  request['Content-Type'] = "application/json"
  datacenter = JSON.parse(http.request(request).body)

  ipaddressuri = URI("http://#{servername}:#{port}#{endpoint}/ipaddress")
  http = Net::HTTP.new(ipaddressuri.host, ipaddressuri.port)
  request = Net::HTTP::Get.new(ipaddressuri)
  request['Content-Type'] = "application/json"
  ipaddress = JSON.parse(http.request(request).body)

  kerneluri = URI("http://#{servername}:#{port}#{endpoint}/kernel")
  http = Net::HTTP.new(kerneluri.host, kerneluri.port)
  request = Net::HTTP::Get.new(kerneluri)
  request['Content-Type'] = "application/json"
  kernel = JSON.parse(http.request(request).body)

  datacenter.each do |d|
    next if d['value'] == 'unknown'
    next if d['value'][/^sp/] #exclude stuff that starts with sp
    next if d['value'] != "NonProd_Facter_DC" and d['value'] != "Prod_Facter_DC" and d['value'] != "Other_DC"
    ipaddress.each do |i|
      if i['certname'] == d['certname']
        servers[d['value']][i['certname']] = i['value']
        datacenter = d['value']
        hostname = i['certname']
        ip = i['value']
        case datacenter #assign zabbix groups for categories/translation to grafana
        when "Prod_Facter_DC"
          grpid = '9'
        when "NonProd_Facter_DC"
          grpid = '11'
        when "Other_DC"
          grpid = '12'
        else
          logger.info "Datacenter value of: #{datacenter} not found. Exiting"
          exit
        end
      
        kernel.each do |k|
          if i['certname'] == k['certname']
            if k['value'] == 'windows'
              # Some day we may setup a Windows set. Maybe. Who knows. For now we are just going to remove the windows hosts if they exist.
              hostid = zbx.hosts.get_id(:host => hostname)
              hostid.nil? || a_hostid.push(hostid)
              hostid.nil? || (p "Removing #{hostname} with Hostid: #{hostid} from Zabbix")
            elsif k['value'] == 'Linux'
              puppet_hostnames.push(hostname)
              zbx.hosts.create_or_update(
                :host       => hostname,
                :interfaces => [
                  {
                    :type   => 1,
                    :main   => 1,
                    :dns    => hostname,
                    :ip     => ip,
                    :port   => 10050,
                    :useip  => 0,
                    :usedns => 1,
                  }
                ],
                :templates => [ :templateid => '10001' ],
                :groups    => [ :groupid => grpid ],
              )

              zbx.hosts.update(
                :hostid     => zbx.hosts.get_id(:host => hostname),
                :templateid => '10001',
              )     
            end
          end
        end
      end
    end
  end
end
# Delete the windows hosts
a_hostid.each do |d|
  zbx.hosts.delete(d)
end

# Create list of known hosts in Zabbix
zbx.hosts.get({}).each do |h|
  unless h['host'] == "Zabbix server" 
    zabbix_hostnames.push(h['host'])
  end
end

# Union puppet hosts with zabbix hosts and get the difference
((zabbix_hostnames-puppet_hostnames) | (puppet_hostnames-zabbix_hostnames)).each do |r|
  remove_hostnames.push(r)
end

# We need to remove hostnames by hostid because the API is crap and can't handle it otherwise
remove_hostnames.each do |a|
  remove_hostid = zbx.hosts.get_id(:host => a)
  remove_hostids.push(remove_hostid)
end

# This is kinda cheating. I could use a hash but I don't care.
remove_hostnames.each do |x|
  logger.info "Removing host #{x} from Zabbix as it is no longer in Puppet."
end

# Actually remove the hosts
remove_hostids.each do |r|
  zbx.hosts.delete(r)
end

# I want to log something to the log.
logger.info "#{Time.now} - Run finished"
