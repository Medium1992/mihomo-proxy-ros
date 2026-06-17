:global AddressList
/ip firewall address-list
:do {add list=$AddressList comment=telegram address=142.252.197.0/24} on-error {}
:do {add list=$AddressList comment=telegram address=172.121.110.0/24} on-error {}
:do {add list=$AddressList comment=telegram address=194.221.0.0/16} on-error {}
:do {add list=$AddressList comment=telegram address=109.239.140.0/24} on-error {}
:do {add list=$AddressList comment=telegram address=5.28.192.0/18} on-error {}
:do {add list=$AddressList comment=facebook address=202.59.209.0/24} on-error {}
:do {add list=$AddressList comment=anthropic address=216.73.216.0/22} on-error {}
