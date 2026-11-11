def in_tag: "in-\(.id)-r\(.inbound_revision)";
def out_tag: "out-\(.id)-r\(.outbound_revision)";
def inbound_settings:
  if .kind=="vless" then {clients:[{id:.credentials.id,flow:(if .security=="reality" then "xtls-rprx-vision" else "" end),email:.id}],decryption:"none"}
  elif .kind=="vmess" then {clients:[{id:.credentials.id,email:.id}]}
  elif .kind=="trojan" then {clients:[{password:.credentials.password,email:.id}]}
  elif .kind=="shadowsocks" then {method:.credentials.method,password:.credentials.password,network:"tcp,udp"}
  elif .kind=="socks" then {auth:"password",accounts:[{user:.credentials.username,pass:.credentials.password}],udp:true}
  elif .kind=="dokodemo-door" then {address:.remote.address,port:.remote.port,network:"tcp,udp"}
  elif .kind=="hysteria" then {version:2,users:[{auth:.credentials.password,email:.id}]}
  else error("unsupported inbound protocol") end;
def base_stream:
  {network:.network} +
  (if .network=="ws" then {wsSettings:{path:.endpoint.path}}
   elif .network=="grpc" then {grpcSettings:{serviceName:(.endpoint.path|ltrimstr("/"))}}
   elif .network=="xhttp" then {xhttpSettings:{path:.endpoint.path,mode:(.xhttp_mode // "auto")}}
   elif .network=="kcp" then {kcpSettings:{mtu:1350,tti:50,uplinkCapacity:12,downlinkCapacity:100,congestion:false,seed:.credentials.seed}}
   elif .network=="hysteria" then {hysteriaSettings:{version:2}}
   else {tcpSettings:{header:{type:(.credentials.header // "none")}}} end);
def server_stream($settings):
  base_stream +
  (if .security=="reality" then
     {security:"reality",realitySettings:{target:(.sni+":443"),serverNames:[.sni],privateKey:.credentials.private_key,shortIds:[.credentials.short_id]}}
   elif .security=="tls" then
     ($settings.certificates[.endpoint.domain] // error("certificate not deployed")) as $cert |
     {security:"tls",tlsSettings:{alpn:(if .kind=="hysteria" then ["h3"] else ["h2","http/1.1"] end),certificates:[{certificateFile:($cert.path+"/fullchain.pem"),keyFile:($cert.path+"/privkey.pem"),oneTimeLoading:true}]}}
   else {security:"none"} end);
def server_inbound($settings):
  {tag:in_tag,listen:(if .security=="nginx" or .manual_tls then "127.0.0.1" else .listen end),
   port:(if .security=="nginx" or .manual_tls then .backend.port else .endpoint.port end),protocol:.kind,
   settings:inbound_settings,streamSettings:server_stream($settings),
   sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}};
def outbound: .outbound + {tag:out_tag};
def client_stream:
  . as $n | base_stream +
  (if .security=="reality" then {security:"reality",realitySettings:{serverName:.sni,fingerprint:"chrome",password:.credentials.public_key,shortId:.credentials.short_id}}
   elif .security=="nginx" or .security=="tls" then {security:"tls",tlsSettings:{serverName:.endpoint.domain,allowInsecure:false,useSystemCA:true,alpn:(if .kind=="hysteria" then ["h3"] elif .network=="ws" then ["http/1.1"] else ["h2","http/1.1"] end)}}
   else {security:"none"} end) |
  if .network=="hysteria" then .hysteriaSettings.auth=$n.credentials.password
  elif .network=="ws" then .wsSettings.host=$n.endpoint.domain
  else . end;
def client_outbound:
  {tag:"proxy",protocol:.kind,streamSettings:client_stream,
   settings:(if .kind=="vless" or .kind=="vmess" then
     {vnext:[{address:.endpoint.address,port:.endpoint.port,users:[({id:.credentials.id} + (if .kind=="vless" then {encryption:"none",flow:(if .security=="reality" then "xtls-rprx-vision" else "" end)} else {security:"auto"} end))]}]}
   elif .kind=="trojan" or .kind=="shadowsocks" then {servers:[{address:.endpoint.address,port:.endpoint.port,password:.credentials.password,method:.credentials.method}]}
   elif .kind=="socks" then {servers:[{address:.endpoint.address,port:.endpoint.port,users:[{user:.credentials.username,pass:.credentials.password}]}]}
   elif .kind=="hysteria" then {version:2,address:.endpoint.address,port:.endpoint.port}
   else error("This protocol has no client export") end)};

. as $state | $state.settings as $s |
{
 log:{access:($root+"/logs/access.log"),error:($root+"/logs/error.log"),loglevel:$s.loglevel},
 api:{tag:"manager-api",listen:$socket,services:["HandlerService","RoutingService","StatsService","LoggerService"]},
 stats:{},policy:{system:{statsInboundUplink:true,statsInboundDownlink:true,statsOutboundUplink:true,statsOutboundDownlink:true}},
 dns:{servers:$s.dns,tag:"manager-dns"},
 inbounds:[$state.nodes[]|server_inbound($s)],
 outbounds:([{tag:"block",protocol:"blackhole"},{tag:"manager-control",protocol:"freedom",settings:{}}]+[$state.nodes[]|outbound]),
 routing:{domainStrategy:"IPOnDemand",rules:(
   [{type:"field",ruleTag:"control-dns",inboundTag:["manager-dns"],outboundTag:"manager-control"}]+
   (if $s.block.bt then [{type:"field",ruleTag:"block-bt",protocol:["bittorrent"],outboundTag:"block"}] else [] end)+
   (if $s.block.private then [{type:"field",ruleTag:"block-private",ip:["geoip:private"],outboundTag:"block"}] else [] end)+
   (if $s.block.cn then [{type:"field",ruleTag:"block-cn",ip:["geoip:cn"],outboundTag:"block"}] else [] end)+
   [$state.nodes[]|select(.outbound.protocol=="http")|{type:"field",ruleTag:("udp-deny-"+.id+"-i"+(.inbound_revision|tostring)),inboundTag:[in_tag],network:"udp",outboundTag:"block"}]+
   [$state.nodes[]|{type:"field",ruleTag:("route-"+.id+"-i"+(.inbound_revision|tostring)+"-o"+(.outbound_revision|tostring)),inboundTag:[in_tag],outboundTag:out_tag}]+
   [{type:"field",ruleTag:"default-deny",network:"tcp,udp",outboundTag:"block"}]
 )}
}
