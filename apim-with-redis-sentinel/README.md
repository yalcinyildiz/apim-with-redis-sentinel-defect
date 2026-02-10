# WSO2 API Manager 4.6.0 — Distributed Throttling with Redis via HAProxy

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Architecture](#2-architecture)
3. [Component Summary](#3-component-summary)
4. [Prepare Local Environment](#4-prepare-local-environment)
5. [Test Functionality](#5-test-functionality)
6. [Test Defect Scenario](#6-test-defect-scenario)

---

## 1. Introduction

WSO2 API Manager components, do not natively support connecting to Redis through Sentinel protocol. They require a **single Redis host:port** endpoint. 

### Solution

Provided solution is to use **HAProxy** layer (`redis-haproxy`) to connect to Redis Sentinel cluster. HAProxy:

- Queries Redis Sentinel to discover the current **master** node.
- Proxies all Redis TCP traffic to the active master.
- Performs health checks to detect master failovers and re-routes traffic automatically.

This gives WSO2 API Manager a stable, single-endpoint Redis connection (`redis-haproxy:6380`).

### Problem Statement

If control plane restarts, then counters in redis will not be reset and throttling will not work as expected.

---

## 2. Architecture

The deployment consists of layers below:

| Layer                                | Service                                                                        |
|--------------------------------------|--------------------------------------------------------------------------------|
| **WSO2 API Manager — Control Plane** | apim-cp                                                                        |
| **WSO2 API Manager — Gateway**       | apim-gateway                                                                   |
| **Redis HAProxy**                    | redis-haproxy                                                                  |
| **Redis HAProxy Watcher**            | redis-haproxy-watcher                                                          |
| **Redis Sentinel Cluster**           | 3 Sentinels (redis-sentinel-n) + 3 Redis nodes (redis-master, redis-replica-n) |


---

## 3. Component Summary

### 3.1 WSO2 API Manager — Control Plane

- **Image:** `wso2/wso2am:4.6.0`
- **Role:** Manages API lifecycle, publishes throttling policies, and runs the Traffic Manager for event-based throttling decisions.
- **Service:** `apim-cp`.
- **Distributed Throttling:** Enabled with `type: redis`.

### 3.2 WSO2 API Manager — Gateway

- **Image:** `wso2/wso2am-universal-gw:4.6.0`
- **Role:** Handles API traffic, enforces rate-limiting policies, validates tokens, and routes requests to backends.
- **Service:** `apim-gateway`.
- **Distributed Throttling:** Enabled with `distributed.counter.type: redis`.

### 3.3 Redis HAProxy Watcher

- **Image:** `redis:8.4.0`
- **Role:** Discovers the current Redis master via Sentinel and updates haproxy configuration.
- **Service:** `redis-haproxy-watcher`.

### 3.4 Redis HAProxy

- **Image:** `haproxy:3.3.1-alpine`
- **Role:** Acts as a TCP proxy between WSO2 components and the Redis Sentinel cluster.
- **Service:** `redis-haproxy`.

---

## 4. Prepare Local Environment

### 4.1 Prerequisites

- [ ] cd [local_folder_to_checkout]
- [ ] git clone https://github.com/yalcinyildiz/apim-with-redis-sentinel-defect.git
- [ ] cd [local_folder_to_checkout]/apim-with-redis-sentinel
- [ ] docker compose up

### 4.2 Add new rate limiting policy

1. Login to [admin portal](https://localhost:9443/admin)
2. Follow "Rate Limiting Policies" -> "Advanced Policies"
3. Hit "Add new policy" button
   1. Name: **100PerMin**
   2. Request count: **100**
   3. Unit time: **1 Minute(s)**
   4. Hit "Update" button

### 4.3 Add new API

1. Login to [publisher portal](https://localhost:9443/publisher)
2. Follow "REST API" -> "Start From Scratch"
   1. Name: **HttpBinAPI**
   2. Context: **/http-bin**
   3. Version: **v1**
   4. Endpoint: **http://httpbin:80**

### 4.4 Update API Resources

1. Follow "Develop" -> "API Configurations" -> "Resources"
   1. HTTP Verb: **GET**
   2. URI Pattern: **/uuid**
2. Hit "Add new operation" button
3. Hit "Save" button
4. Click on "get /uuid" resource
5. Disable security
6. Select "100PerMin" policy
7. Hit "Save" button
8. Delete all resources with wildcard
9. Hit "Save and Deploy" button
10. Hit "Deploy" button

---

## 5. Test functionality

### 5.1 Prerequisites

You can either use `curl` or `Postman` to run load tests. If you have JMeter, you can directly import [this document](docs/Throttling-test.jmx) for testing. 

### 5.2 Run Load Test

Using your favorite tool, run load test to see if throttling works as expected. Be sure to call `http://localhost:8280/http-bin/v1/uuid` endpoint more than 100 times in a minute. After 100 requests, you will get a response with `429` status code.

```
curl -X GET http://localhost:8280/http-bin/v1/uuid -v
Note: Unnecessary use of -X or --request, GET is already inferred.
* Host localhost:8280 was resolved.
* IPv6: ::1
* IPv4: 127.0.0.1
*   Trying [::1]:8280...
* Established connection to localhost (::1 port 8280) from ::1 port 64216
* using HTTP/1.x
> GET /http-bin/v1/uuid HTTP/1.1
> Host: localhost:8280
> User-Agent: curl/8.17.0
> Accept: */*
>
< HTTP/1.1 429 Too Many Requests
< activityid: 8008a809-e4c9-4245-a0e7-8fff948e0f81
< Retry-After: Tue, 10 Feb 2026 16:20:00 GMT
< Access-Control-Allow-Origin: *
< Content-Type: application/json; charset=UTF-8
< Date: Tue, 10 Feb 2026 16:19:07 GMT
< Transfer-Encoding: chunked
<
{"code":"900802","message":"Message throttled out","description":"You have exceeded your quota .You can access API after 2026-Feb-10 16:20:00+0000 UTC","nextAccessTime":"2026-Feb-10 16:20:00+0000 UTC"}
```

### 5.3 Check Redis

You can run the following command to check redis keys:

```
docker compose exec redis-haproxy-watcher sh -lc "redis-cli -h redis-haproxy -p 6380 -a redispass KEYS '*'"
1) "wso2_throttler:192.168.143.2:/http-bin/v1:v1:Unauthenticated::"
2) "wso2_throttler:/http-bin/v1/v1/uuid:GET_default::"
```

To see the counter value:

```
docker compose exec redis-haproxy-watcher sh -lc 'redis-cli -h redis-haproxy -p 6380 -a redispass GET "wso2_throttler:/http-bin/v1/v1/uuid:GET_default::"'
"100"
```

In 1 minute, the counter should be reset to 0 in Redis.

---

## 6. Test Defect Scenario

### 6.1 Run Load Test

Using your favorite tool, rerun load test. Be sure to call `http://localhost:8280/http-bin/v1/uuid` endpoint more than 100 times in a minute. After 100 requests, you will get a response with `429` status code.

### 6.2 Restart Control Plane

Run the command below in the same minute to restart control plane:

```
docker compose restart --no-deps apim-cp
```

### 6.3 Check Redis

You can run the following command to check redis counter value:

```
docker compose exec redis-haproxy-watcher sh -lc 'redis-cli -h redis-haproxy -p 6380 -a redispass GET "wso2_throttler:/http-bin/v1/v1/uuid:GET_default::"'
"100"
```

The counter value is not reset to 0 in Redis.

### 6.4 Observe Behavior After Control Plane Restart

If you call `http://localhost:8280/http-bin/v1/uuid` endpoint more than 1 times in a minute, you will see the second request returns `429` status code.

The first request returns `200` status code.

```
curl -X GET http://localhost:8280/http-bin/v1/uuid -v
Note: Unnecessary use of -X or --request, GET is already inferred.
* Host localhost:8280 was resolved.
* IPv6: ::1
* IPv4: 127.0.0.1
*   Trying [::1]:8280...
* Established connection to localhost (::1 port 8280) from ::1 port 65529 
* using HTTP/1.x
> GET /http-bin/v1/uuid HTTP/1.1
> Host: localhost:8280
> User-Agent: curl/8.17.0
> Accept: */*
> 
< HTTP/1.1 200 OK
< activityid: 754f4ec7-bcff-48f8-9457-04a77fc093bd
< Access-Control-Allow-Origin: *
< Access-Control-Allow-Credentials: true
< Content-Type: application/json
< Date: Tue, 10 Feb 2026 16:24:16 GMT
< Transfer-Encoding: chunked
< 
{
  "uuid": "91c8bf13-b310-4c2a-84b2-a07163fdb6d6"
}

```

The second request returns `429` status code.

```
curl -X GET http://localhost:8280/http-bin/v1/uuid -v
Note: Unnecessary use of -X or --request, GET is already inferred.
* Host localhost:8280 was resolved.
* IPv6: ::1
* IPv4: 127.0.0.1
*   Trying [::1]:8280...
* Established connection to localhost (::1 port 8280) from ::1 port 62913 
* using HTTP/1.x
> GET /http-bin/v1/uuid HTTP/1.1
> Host: localhost:8280
> User-Agent: curl/8.17.0
> Accept: */*
> 
* Request completely sent off
< HTTP/1.1 429 Too Many Requests
< activityid: 03f86996-3540-41a7-869f-e8239f51ecbc
< Retry-After: Tue, 10 Feb 2026 16:25:00 GMT
< Access-Control-Allow-Origin: *
< Content-Type: application/json; charset=UTF-8
< Date: Tue, 10 Feb 2026 16:24:19 GMT
< Transfer-Encoding: chunked
< 
{"code":"900802","message":"Message throttled out","description":"You have exceeded your quota .You can access API after 2026-Feb-10 16:25:00+0000 UTC","nextAccessTime":"2026-Feb-10 16:25:00+0000 UTC"}
```

If you check Redis, you will see the counter value is incremented by 1.

```
docker compose exec redis-haproxy-watcher sh -lc 'redis-cli -h redis-haproxy -p 6380 -a redispass GET "wso2_throttler:/http-bin/v1/v1/uuid:GET_default::"'
"101"
```
