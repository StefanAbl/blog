FROM klakegg/hugo AS builder
WORKDIR /workdir
COPY . /workdir
RUN hugo

FROM nginx
COPY --from=builder /workdir/public /usr/share/nginx/html
RUN sed -i 's/listen *80;/listen 8080;/g' /etc/nginx/conf.d/default.conf