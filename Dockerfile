FROM klakegg/hugo AS builder
WORKDIR /workdir
COPY . /workdir
RUN mkdir -p /var/www/html && hugo

FROM nginx
COPY --from=builder /workdir/public /usr/share/nginx/html