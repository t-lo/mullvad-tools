FROM alpine:3.23

RUN apk upgrade
RUN apk add wireguard-tools curl jq bash ip6tables sudo iproute2
COPY ./entry.sh /opt/mullvad/
ENTRYPOINT [ "/opt/mullvad/entry.sh" ]
