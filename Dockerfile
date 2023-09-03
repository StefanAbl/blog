FROM klakegg/hugo:alpine AS builder
RUN apk add --update --no-cache git
WORKDIR /workdir
COPY . /workdir
RUN git submodule init && \
  git submodule update && \
  hugo --panicOnWarning && \
  sed -i 's/.*_internal\/google_analytics.html.*//g' themes/PaperMod/layouts/partials/head.html && \
  ls -lah public/*

FROM nginx
COPY --from=builder /workdir/public /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf
RUN nginx -t && ls -lah /usr/share/nginx/html