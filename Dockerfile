FROM klakegg/hugo:alpine AS builder
WORKDIR /workdir
COPY . /workdir
RUN apk add --update --no-cache git
RUN git submodule init && git submodule update && hugo --panicOnWarning  && ls -lah public/*

FROM nginx
COPY --from=builder /workdir/public /usr/share/nginx/html
RUN sed -i 's/listen *80;/listen 8080;/g' /etc/nginx/conf.d/default.conf && ls -lah /usr/share/nginx/html