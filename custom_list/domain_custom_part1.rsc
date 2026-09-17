:global AddressList
:global ForwardTo
/ip dns static
:if ([:len [find name="flashscorekz.com"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="flashscore" match-subdomain=yes type=FWD name="flashscorekz.com" }
:if ([:len [find name="fsdatacentre.com"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="flashscore" match-subdomain=yes type=FWD name="fsdatacentre.com" }
:if ([:len [find name="flashscore.com"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="flashscore" match-subdomain=yes type=FWD name="flashscore.com" }
:if ([:len [find name="flashscore.ninja"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="flashscore" match-subdomain=yes type=FWD name="flashscore.ninja" }
:if ([:len [find name="static.flashscore.com.cdn.cloudflare.net"]] = 0) do={ add address-list=$AddressList forward-to=$ForwardTo comment="flashscore" match-subdomain=yes type=FWD name="static.flashscore.com.cdn.cloudflare.net" }
