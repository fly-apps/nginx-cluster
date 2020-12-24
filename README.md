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

### Discovering nodes

Making this cluster topology work properly is an exercise in service discovery. The Fly DNS service always has a current list of IPv6 Private Network (6PN) addresses for VMs in a given app. The `dig` utility can query the DNS service for _all_ running VMs in a given application:

```
dig aaaa $FLY_APP_NAME.internal @fdaa::3 +short
```
```
fdaa:0:1:a7b:7b:0:5f1:2
fdaa:0:1:a7b:7f:0:5f2:2
```

It can also query by region:
```
dig aaaa dfw.$FLY_APP_NAME.internal @fdaa::3 +short
```

We can use these to keep `nginx.conf` updated with a list of servers. This happens in two places:

1. `start.sh` preps the `nginx.conf` file, calls `check-nodes.sh`, and then boots NGINX
2. `check-nodes.sh` uses `dig` to find the list of servers _in the same region_ and write `upstream` block with known 6pn addresses. This script runs periodically to keep things fresh.

This is how a basic CDN works. Multiple cache nodes in each region, each requests from origin when it needs a file, and caches it for later. Each region will still need to warm its own cache to get snappy.

### An aside about onions

Letting each region manage origin requests is simple, but not always ideal. A common pattern for "fixing" this is to make origin requests from one region, cache there, and then let each region use that cache as its own origin. It's a layer of caches, like an onion!

An request to an onion might look like this:

```
( ͡° ͜ʖ ͡°)  ----> nginx sydney --> nginx ord --> origin
```

This has several advantages, and one major complication:

First, it greatly reduces origin load. If only one server is able to make requests to the origin for a specific URL, it's simple to throttle origin requests. Our `nginx.conf` actuall does this by setting `proxy_cache_lock on`, ensuring that we only make one request per URL at a time.

And, it's usually faster. Requests served from our cache in Chicago are going to be faster than requests served from origin. And even for uncached requests, our network connection between Sydney and Chicago is _usually_ better than our connection between Sydney and the origin. Routing requests through Chicago to an origin is likely faster.

The downside is resiliency. With this kind of setup, if we lose our Chicago datacenter we suddenly can't talk to the origin. We'd need to add a fallback region. 

### Deploying a CDN

The NGINX features we're using have been around for _ages_. They were built long before 2020. But deploying a CDN has, historically, been beyond the scope of a single developer. This is part of the reason we built Fly, we think ops can be automated and individual developers can ship their own CDNs.

So here's how to deploy a shiny, horizontally scalable CDN in about 5 minutes.

### Create a Fly app

The quickest way to create an app is to import the `fly.source.toml` file we created for you:

```
fly init gif-cache-example --import fly.source.toml
```

Replace `gif-cache-example` with your preferred app name or omit it to have Fly generate a name for you. You may be prompted for which organization you want the app to run in. 

Our NGINX config runs on port 8080, so the `fly.toml` instructs Fly to route HTTP and HTTPS traffic to port 8080.

NGINX needs disks, so go ahead and create one or more volumes (you'll need one volume per node when you scale out):

```
flyctl volumes create nginx_data --region dfw --size 500
```

This creates a 500GB volume named `nginx_data` in Dallas. You can add more volumes in Dallas, or put them in other regions, just make sure they're all named `nginx_data`.

To deploy the app, run:

```
fly deploy
```

Congrats! You now have a single server GIF cache running with global anycast IPs routing your traffic (run `flyctl info`).

Scaling is just a matter of adding volumes for your next VMs. Add 'em in the regions you want, put multiples in the regions you want to shard, and then scale your app out:

```
flyctl scale count 3
```

Now you have three total NGINX servers running, each with its own disk. Requests with the same URL route to the same server.

## See it in action with cURL

Fire up your terminal and run this command to make a request to our example GIF caching service, and print the headers out:

```
curl -D - -o /dev/null -sS https://nginx-cluster-example.fly.dev/media/7twIWElrcmnzW/source.gif
```
```
HTTP/2 200
server: Fly/004c36a8 (2020-12-08)
date: Wed, 23 Dec 2020 23:49:39 GMT
content-type: image/gif
content-length: 2085393
accept-ranges: bytes
last-modified: Sat, 13 Jul 2019 04:40:21 GMT
etag: "00e2a6744ab9aea25e6e3ca20e0fe46f"
via: 1.1 varnish, 1.1 varnish, 2 fly.io
access-control-allow-origin: *
cross-origin-resource-policy: cross-origin
age: 0
x-served-by: cache-bwi5134-BWI, cache-iah17254-IAH
x-cache: HIT, MISS
x-cache-hits: 1, 0
x-timer: S1608767381.985906,VS0,VE30
strict-transport-security: max-age=86400
cache-control: max-age=86400
fly-cache-status: MISS
x-instance: d12f720f
```

There are some special headers here:

* `x-instance` – specifies the ID of the server that sent the response. This should be the same each time you run cURL with that URL
* `fly-cache-status` – indicates if a request was served from the cache or not.

If we run the same curl again, the `x-instance` remains unchanged, and the `fly-cache-status` shows a `HIT`.

But if we try a different URL:

```
curl -D - -o /dev/null -sS "https://nginx-cluster-example.fly.dev/media/l1KVcBV7rstepCYhi/giphy.gif"
```

```
HTTP/2 200
server: Fly/004c36a8 (2020-12-08)
date: Wed, 23 Dec 2020 21:05:02 GMT
content-type: image/gif
content-length: 3946398
accept-ranges: bytes
last-modified: Wed, 12 Apr 2017 19:14:41 GMT
etag: "81630bf6b606ff600f90dc91a9dbd0a1"
via: 1.1 varnish, 1.1 varnish, 2 fly.io
access-control-allow-origin: *
cross-origin-resource-policy: cross-origin
age: 50421
x-served-by: cache-bwi5135-BWI, cache-iah17222-IAH
x-cache: HIT, HIT
x-cache-hits: 117, 1
x-timer: S1608753636.146957,VS0,VE1
strict-transport-security: max-age=86400
cache-control: max-age=86400
fly-cache-status: HIT
x-instance: 3d727da8
```

The `x-instance` header indicates it came from a different server.

<hr>

## Where to go from here

HTTP caching is simple, but global cache expiration is hard. Users will want to clear the cache when their app changes, or they need to delete stale data for other reasons, and "immediate cache expiration" is a spiff feature to offer. If we were going to build that, we'd build a little worker that runs with each NGINX server and listens for purge events from [NATs](https://github.com/fly-examples/nats-cluster).

People who build snappy apps spend a lot of time optimizing images. CDNs can do that! This NGINX cluster could work with [`imgproxy`](https://fly.io/launch/github/imgproxy/imgproxy) or ['imaginary'](https://fly.io/launch/github/h2non/imaginary) to automatically cache and serve webp images, add classy visual effects, and even do smart cropping.

(You might notice that each of these involve running _more_ VMs on Fly. Total coincidence.)