FROM nginx:1.19.5

RUN apt-get update && apt-get install -yq dnsutils vim-tiny iputils-ping procps && apt-get clean && rm -rf /var/lib/apt/lists

ADD nginx.conf /etc/nginx/nginx.conf
ADD /scripts /fly
ENV NGINX_PORT=8080


RUN curl -L https://github.com/DarthSim/hivemind/releases/download/v1.1.0/hivemind-v1.1.0-linux-amd64.gz -o hivemind.gz \
  && gunzip hivemind.gz \
  && mv hivemind /usr/local/bin

COPY Procfile Procfile
RUN chmod +x /usr/local/bin/hivemind
RUN chmod +x /fly/*.sh

CMD ["/usr/local/bin/hivemind"]