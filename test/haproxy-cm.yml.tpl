apiVersion: v1
kind: ConfigMap
metadata:
  name: haproxy-config
  namespace: {{ kubernetes_namespace }}
data:
  haproxy.cfg: |

   global
     maxconn 15000 # Max simultaneous connections from an upstream server
     spread-checks 5 # Distribute health checks with some randomness
     log 127.0.0.1 local0
     #debug # Uncomment for verbose logging
     tune.ssl.default-dh-param 2048
     ssl-default-bind-options no-sslv3 no-tls-tickets no-tlsv10
     ssl-default-bind-ciphers EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH

   defaults # Apply to all http services
     log global
     mode http
     balance roundrobin
     option abortonclose # abort request if client closes output channel while waiting
     option httpclose # add "Connection:close" header if it is missing
     option forwardfor # insert x-forwarded-for header so that app servers can see both proxy and client IPs
     option redispatch # any server can handle any session
     option httplog
     timeout client 60s
     timeout connect 9s
     timeout server 60s
     timeout check 5s

   frontend main
     bind *:443 ssl crt {{ haproxy_cert_dir}}/haproxy.pem
     reqadd X-Forwarded-Proto:\ https
     acl routerservice path_beg /routerservice
     acl phispheremanager path_beg /phispheremanager
     acl administration path_beg /administration
     acl manage path_beg /manage
     acl consume path_beg /consume
     acl monitor path_beg /monitor
     acl orchestration path_beg /orchestration
     acl usermanagement path_beg /idm
     acl notification path_beg /notification
     acl billing path_beg /billing
     acl serviceextension path_beg /serviceextension
     acl reporting path_beg /reporting
   {% if enable_kubernetes_dashboard == true %}
     acl kubernetes-dashboard path_beg /kubernetes-dashboard
     acl kube_whitelist src {{ kubernetes_whitelist }}
     block if kubernetes-dashboard !kube_whitelist
   {% endif %}
   {% if enable_kibana_dashboard == true %}
     acl kibana path_beg /kibana
     acl kibana_whitelist src {{ kibana_whitelist }}
     block if kibana !kibana_whitelist
   {% endif %}

     acl devicemanagerservice path_beg /devicemanagerservice

   {% if enable_kubernetes_dashboard == true %}

     http-request replace-value Host (.*)  haproxyvms8080.cisco.com unless routerservice || phispheremanager || administration || manage || consume || monitor || orchestration || usermanagement || notification || serviceextension || billing || reporting || kubernetes-dashboard || devicemanagerservice {% if enable_kibana_dashboard == true %} || kibana {% endif %}
   {% endif %}
   {% if enable_kubernetes_dashboard == false %}
     http-request replace-value Host (.*)  haproxyvms8080.cisco.com unless routerservice || phispheremanager || administration || manage || consume || monitor || orchestration || usermanagement || notification || serviceextension || billing || reporting || devicemanagerservice {% if enable_kibana_dashboard == true %} || kibana {% endif %}
   {% endif %}

     http-request set-path /routerservice%[path] if administration || manage || consume || monitor || orchestration || usermanagement || notification || serviceextension || billing || reporting || devicemanagerservice

   {% if enable_kubernetes_dashboard == true %}
     use_backend kong if kubernetes-dashboard
   {% endif %}

   {% if enable_kibana_dashboard == true %}
     use_backend kong if kibana
   {% endif %}


   {% if 'pnp-instance' in inventory_hostname %}
     default_backend pnp

   backend pnp
     server master.nso-ha master.nso-ha.service.consul:443 check inter 5000 fastinter 1000 fall 1 rise 1 weight 1 maxconn 1000 ssl verify none
   {% else %}
     default_backend waf
   {% endif %}


   resolvers vmsdns
     {% for host in groups['kube-master'] %}
     nameserver dns{{ loop.index }} {{ hostvars[host]['ansible_default_ipv4']['address'] }}:53
     {% endfor %}
     resolve_retries 3
     timeout retry   2s
     hold valid      10s

   frontend wafredirect
     http-response set-header Strict-Transport-Security "max-age=16000000; includeSubdomains; preload;"
     http-response set-header Content-Security-Policy "base-uri 'self'; default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://maps.googleapis.com https://maps.gstatic.com http://maps.googleapis.com http://maps.gstatic.com https://{{ vms_subdomain }}.{{ vms_domain }}; font-src 'self' data: https://fonts.googleapis.com http://fonts.googleapis.com https://fonts.gstatic.com http://fonts.gstatic.com https://{{ vms_subdomain }}.{{ vms_domain }}; connect-src 'self' https://{{ vms_subdomain }}.{{ vms_domain }}:8765 https://{{ vms_subdomain }}.{{ vms_domain }}; img-src 'self' data: https://maps.googleapis.com https://maps.gstatic.com http://maps.googleapis.com http://maps.gstatic.com  https://{{ vms_subdomain }}.{{ vms_domain }}; style-src 'self' 'unsafe-inline' http://maps.googleapis.com https://maps.gstatic.com https://fonts.googleapis.com http://fonts.googleapis.com https://{{ vms_subdomain }}.{{ vms_domain }}; frame-ancestors 'self'; block-all-mixed-content;"
     bind *:81
     default_backend kong

   backend waf
     option httplog
     server waf 127.0.0.1:8080  check inter 5000 maxconn 1000

   backend kong
     option httplog
     acl hdr_location res.hdr(Location) -m found
     compression algo gzip
     compression offload
     compression type text/css text/html text/javascript application/javascript text/plain text/xml application/json

     rspirep ^Location:\ http://(.*):80(.*)  Location:\ https://\1:443\2 if hdr_location
     rspirep ^Location:\ https://(.*):80(.*)  Location:\ https://\1:443\2 if hdr_location
     rspirep ^Location:\ (https?://vmsui-svc.{{ kubernetes_namespace }}.svc.{{ kubedns_domain }}(:[0-9]+)?)?(/.*) Location:\ \3 if hdr_location

server kong {{ kong_consul_host }} resolvers vmsdns check inter 1000 maxconn 5000