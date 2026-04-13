FROM ubuntu:latest

WORKDIR /home/

RUN curl -fsSL https://public.cdn.getdbt.com/fs/install/install.sh | sh -s -- --update

COPY . .
