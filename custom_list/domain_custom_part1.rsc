:global AddressList
:global ForwardTo
/ip dns static
:if ([:len [find name="cdn-service.space"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="cdn-service.space" }
:if ([:len [find name="cdn-service.online"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="cdn-service.online" }
:if ([:len [find name="alador.space"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="alador.space" }
:if ([:len [find name="vps-b8b894e6.vps.ovh.net"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="vps-b8b894e6.vps.ovh.net" }
:if ([:len [find name="api2.support-kp.com"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="api2.support-kp.com" }
:if ([:len [find name="kpdl.link"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="kpdl.link" }
:if ([:len [find name="kpserver.link"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="kpserver.link" }
:if ([:len [find name="proxykp.xyz"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="proxykp.xyz" }
:if ([:len [find name="teleos.club"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="teleos.club" }
:if ([:len [find name="smarttvcdn.online"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="smarttvcdn.online" }
:if ([:len [find name="digital-cdn.net"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="digital-cdn.net" }
:if ([:len [find name="mycdn.video"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="mycdn.video" }
:if ([:len [find name="cdntogo.net"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="cdntogo.net" }
:if ([:len [find name="cdn32.lol"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="cdn32.lol" }
:if ([:len [find name="flexcdn.cloud"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="kinopub" match-subdomain=yes type=FWD name="flexcdn.cloud" }
