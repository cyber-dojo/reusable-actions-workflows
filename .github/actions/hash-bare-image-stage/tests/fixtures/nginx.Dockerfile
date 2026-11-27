# Pinned to the tag's multi-platform index digest, not one platform's manifest,
# so the same pin serves the linux/amd64 and linux/arm64 builds.
FROM nginx:stable-alpine3.23@sha256:0d3b80406a13a767339fbe2f41406d6c7da727ab89cf8fae399e81f780f814d1
LABEL maintainer=jon@jaggersoft.com

RUN apk add bash tini
RUN apk upgrade

# Remove curl (and libcurl, which only curl needs). nginx never uses curl at
# runtime, so deleting it clears the recurring Alpine libcurl CVEs from the
# Snyk scan instead of waiting for each Alpine fix to be published. Mirrors the
# equivalent removal (of git) in the runner repo's Dockerfile.
RUN apk del curl

ARG NGINX_DIR=/usr/share/nginx/html
RUN      rm -rf ${NGINX_DIR}
COPY     images ${NGINX_DIR}/images
RUN chmod -R +r ${NGINX_DIR}
COPY bootstrap.sh /

ARG COMMIT_SHA
ENV SHA=${COMMIT_SHA}

COPY nginx.conf.template        /docker-entrypoint.d
COPY ports.docker.env           /docker-entrypoint.d
COPY ports.k8s.env              /docker-entrypoint.d
COPY ports.ecs.env              /docker-entrypoint.d
COPY template-port-env-subst.sh /docker-entrypoint.d

COPY gzip.conf  /etc/nginx/conf.d/gzip.conf

ENTRYPOINT ["/sbin/tini", "-g", "--"]
CMD [ "/bootstrap.sh" ]
