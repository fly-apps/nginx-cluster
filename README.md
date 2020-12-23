# A horizontally scalable NGINX caching cluster

NGINX is a proxy server that makes HTTP caching simple. Run it in front of an app, set the right HTTP caching headers, and it does its job. If you want to build a basic CDN, you can NGINX in multiple cities, route people to the nearest instance, and apply a little magic.

This is a Docker based NGINX cluster that works kind of like a CDN. It's designed to run on [Fly.io](https://fly.io) with persistent volumes and private networking (6PN). It also runs locally so you can fiddle around with it.

### Speedrun

1. Create an application on Fly
2. Add volumes with `flyctl volumes create`
3. `flyctl deploy`
4. `flyctl scale ???` to scale horizontally
5. Launch your CDN

## Cache hit ratios and penny pinching

People building CDNs want almost every request to come from the cache. In a perfect world, the first person to visit a URL would suffer a slow response, and the second through millionth people would get quick cache responses. With one NGINX, this works great. With two, the chance of a miss is doubled (because each cache is independent). With 100, gross.

There's also the cost of storage. People running CDNs want to make a bunch and buying extra storage is a good way to make less money. It's cheaper to cache a single copy of a file than two.

The NGINX upstream module responsible for load balancing has a handy [`consistent_hash`](https://www.nginx.com/resources/wiki/modules/consistent_hash/) option designed specifically to solve this class of problem.

> `ngx_http_upstream_consistent_hash` - a load balancer that uses an internal consistent hash ring to select the right backend node

This gives us a way to tell NGINX to send requests for the same content to the same "upstream" server.

## Let's build a Giphy cache

Giphy has a bunch of great GIFs, but what if they slow down? GIFs are mission critical for some apps, it would be nice to keep the ones we care about fast. Send people GIFs in a jiffy.

First up, we need to tell NGINX where to get its GIFs (otherwise known as he origin). We can do that with `proxy_pass`, instructing NGINX to pass requests to `media.giphy.com` and see what it says.

```nginx
location / {
    proxy_pass https://media.giphy.com/;
    proxy_cache http_cache;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_cache http_cache;
}
```

The `proxy_cache` line in this block tells NGINX to cache requests (when it can) using a cache named `http_cache`.

```nginx
proxy_cache_path /data/nginx-cache levels=1:2 keys_zone=http_cache:128m max_size=500g inactive=3d use_temp_path=off;
```

This gives us a 500GB cache named `http_cache`, and the files are stored at `/data/nginx-cache`. As long as we have a 500GB disk for NGINX to use, this is all we need – it'll evict files when storage gets tight.

### Load balancers all the way down

We can turn this into a GIF cache cluster by running extra nodes, including them in a load balancer pool, defining the consistent hash key, and then checking to make sure the config has all the necessary semicolons (a special feature of NGINX configurations is how hard it is to debug a missing semicolon).

```nginx
upstream nginx-nodes {
    hash "$scheme://$host$request_uri" consistent;
    keepalive 100;

    server node1:8081 max_fails=5 fail_timeout=1s;
    server node2:8081 max_fails=5 fail_timeout=1s;
}
```

This tells NGINX to use the full URL (including scheme and host) to hash consistently, and send requests to port `8081` on `node1` and `node2`. And it says to consider those nodes bad if they fail 5 times in one second, which means we can retry the request on another. 

Since we're deploying a cluster of nodes, we're instructing nginx to load balance across the _other_ nodes in the cluster.

