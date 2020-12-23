FROM nginx:1.19.5

RUN apt-get update && apt-get install -yq dnsutils vim-tiny iputils-ping procps && apt-get clean && rm -rf /var/lib/apt/lists

ADD nginx.conf /etc/nginx/nginx.conf
ADD /scripts /fly
ENV NGINX_PORT=8080

CMD ["/fly/start.sh"]