#!/usr/local/bin/ruby
require 'json'
require 'fog'
require 'digest/md5'
require 'graph'
require 'mixlib/cli'

ELBDESC='amazon-elb-sg'
ANYWHERE='0.0.0.0/0'

def md5(str="")
	return Digest::MD5.hexdigest(str)
end

def getGroupDesc(x=Hash.new)
	return (x.has_key?('groupName') && !x['groupName'].empty? ? "#{x['groupId']} (#{x['groupName']})" : "#{x['groupId']}")
end

def getSubnetDesc(x="")
	ret="NA"
	if x.nil? || x.empty?
		ret="NA"
	else	
		ip, maskbits = x.split('/')
		if maskbits.to_i==32 #Bah, assuming ipv4 only for now.
			ret="Host #{ip}"
		else
			ret="IP-Subnet #{ip}/#{maskbits}"
		end
	end
	return ret
end

def groupByProto(x=Array.new)
	grouped=Hash.new
	x.each do |thispp|
		proto, port = thispp.split(":")
		proto.upcase!
		port=(port.nil? || port.empty?) ? "ANY" : port.to_i
		grouped[proto]=[] unless grouped.has_key?(proto)
		grouped[proto].push(port)
	end
	str=grouped.keys.map {|y| "#{y}[#{grouped[y].sort{|a1,a2| a1<=>a2}.join(",")}]"}.join(" ")
	return str
end

class Options 
	include Mixlib::CLI

	option :region, :short =>'-r REGION', :long => '--region REGION',:default => 'us-west-2',:description => "AWS Region for which to describe Security groups"
	option :srcre, :short => '-s SRC', :long => '--source SOURCE', :default => '.*', :description => 'Regexp to filter results to match by Source IP/Groups/Groupname. Default is to match all.'
	option :dstre, :short => '-d DEST', :long => '--dest DEST', :default => '.*', :description => 'Regexp to filter results to match by Destination SecGroup. Default is to match all.'
	option :help, :short =>'-h', :long => '--help', :boolean => true, :default => false, :description => "Show this Help message.", :show_options => true, :exit => 0
	option :nograph, :short =>'-n', :long => '--nograph', :boolean => true, :default => false,:description => "Disable PNG/SVG object generation. False by default."
	option :json, :short => '-j', :long => '--json', :boolean => true, :default => false, :description => "Dump the JSON from which SVG/PNG is built"
	option :filename, :short => '-f FILENAME', :long => '--filename FILENAME', :default => "/tmp/sgmap", :description => "Filename (no svg/png suffix) to dump map into. Defaults to /tmp/sgmap(.svg)"
	option :format, :short => '-m FORMAT', :long => '--mode FORMAT', :default => 'svg', :description => "svg/png only - For generated graph. Defaults to svg"
end

#Send a graphviz color each time (and rotate back to front when done) - Excludes certain colors intentionally.
class Allcolors

  def initialize
    @allcolors=Graph::LIGHT_COLORS + Graph::BOLD_COLORS
    @allcolors.delete_if {|c| c=~/^(purple|mediumblue|white|black|maroon|darkgreen|midnightblue|darkviolet|darkorchid|royalblue)$/}
    @clength=@allcolors.length-1
    @ptr=0
  end

  def getNext
    col=@allcolors[@ptr]
    @ptr+=1
    @ptr=0 if @ptr > @clength
    return col
  end
end

cli=Options.new
cli.parse_options

THISREGION=cli.config[:region]
SrcRe=Regexp.new(cli.config[:srcre])
DstRe=Regexp.new(cli.config[:dstre])
abort "No region specified in config." if THISREGION.nil?

fogobj = Fog::Compute.new(
    :provider => 'AWS',
    :region => THISREGION,
    :aws_access_key_id => ENV['AWS_ACCESS_KEY_ID'],
    :aws_secret_access_key => ENV['AWS_SECRET_ACCESS_KEY']
)
raw=fogobj.describe_security_groups.body['securityGroupInfo'].reject {|x| x['groupName']=~/OpsWorks/ || x['ipPermissions'].length==0}
#puts JSON.pretty_generate(raw)

sghash=Hash.new #sg-xxx => sg-description
sources=Hash.new

raw.each do |thisg|
	tgtgroupdesc=getGroupDesc(thisg)
	sghash[ thisg['groupId' ] ]=tgtgroupdesc
	next unless tgtgroupdesc.match(DstRe)
	thisg['ipPermissions'].each do |this_allowed|
		proto_port_combo=this_allowed['ipProtocol']+":"+this_allowed['toPort'].to_s
		proto_port_combo="ANY" if proto_port_combo=="-1:"
		#The "source" could be either a IP subnet or another security group.
		this_allowed['groups'].each do |x|
			#srcid=getGroupDesc(x)	
			if x.has_key?('userId') && x['userId']=='amazon-elb'
				sghash[ thisg['groupId' ] ]=x['groupId'] + "(#{ELBDESC})"
			end
			srcid=x['groupId']
			next unless srcid.match(SrcRe)
			sources[srcid]={'allowed_into'=>Hash.new} unless sources.has_key?(srcid)
			sources[srcid]['allowed_into'][tgtgroupdesc]=[] unless sources[srcid]['allowed_into'].has_key?(tgtgroupdesc)
			sources[srcid]['allowed_into'][tgtgroupdesc].push(proto_port_combo)			
		end	
		this_allowed['ipRanges'].each do |y|
			srcid=getSubnetDesc(y['cidrIp'])
			next unless srcid.match(SrcRe)
			sources[srcid]={'allowed_into'=>Hash.new} unless sources.has_key?(srcid)
			sources[srcid]['allowed_into'][tgtgroupdesc]=[] unless sources[srcid]['allowed_into'].has_key?(tgtgroupdesc)
			sources[srcid]['allowed_into'][tgtgroupdesc].push(proto_port_combo)
		end				
	end	
end


puts JSON.pretty_generate(sources) if cli.config[:json]
exit if cli.config[:nograph]

colors=Allcolors.new
colmap=Hash.new

iphosts=[]
#Try to graph it. Each key in sources will be a node
digraph do
	label "Security Groups in #{THISREGION.upcase}"
	sources.keys.sort.each do |thissrc|
		srcdesc=sghash.has_key?(thissrc) ? sghash[thissrc] : thissrc
		colmap[srcdesc]=send(colors.getNext) unless colmap.has_key?(srcdesc)  
		n=node(srcdesc)
		n.attributes << colmap[srcdesc] + filled
		iphosts << srcdesc if srcdesc=~/^Host /
		sources[thissrc]['allowed_into'].keys.sort.each do |thistgt|
			thistgt=sghash.has_key?(thistgt) ? sghash[thistgt] : thistgt
			note=groupByProto(sources[thissrc]['allowed_into'][thistgt])
			colmap[thistgt]=send(colors.getNext) unless colmap.has_key?(thistgt)		
			t=node(thistgt)
			t.attributes << colmap[thistgt]
			t.attributes << filled
			edge(srcdesc, thistgt).label(note).attributes << colmap[srcdesc] #Edge set to same color as SRC
		end		
	end	

	save cli.config[:filename], cli.config[:format]
end

$stderr.puts "Wrote map to #{cli.config[:filename]}.#{cli.config[:format]}"