###
# STAGE 1: BUILD HERCULES
# We'll build Hercules on Debian Bullseye's "slim" image.
# This minimises dependencies and download times for the builder.
###
FROM --platform=${TARGETPLATFORM:-linux/arm/v6} debian:bullseye-slim AS build_hercules
ARG TARGETPLATFORM

# Update package lists
RUN apt-get update

# Install build dependencies.
RUN apt-get install -y \
  gcc \
  git \
  libmariadb-dev \
  libmariadb-dev-compat \
  libpcre3-dev \
  libssl-dev \
  make \
  zlib1g-dev \
  curl

# Create a build user
RUN adduser --home /home/builduser --shell /bin/bash --gecos "builduser" --disabled-password builduser

# Copy the Hercules build script and distribution template
COPY --chown=builduser builder /home/builduser

# Download and extract SQL files based on HERCULES_SERVER_MODE
RUN if [ "${HERCULES_SERVER_MODE}" = "classic" ]; then \
      curl https://s3.thekao.cloud/public/ragnarok/ro-herc-classic-sql.tar.gz -o /home/builduser/sql-files.tar.gz; \
    else \
      curl https://s3.thekao.cloud/public/ragnarok/ro-herc-renewal-sql.tar.gz -o /home/builduser/sql-files.tar.gz; \
    fi && \
    tar -xzf /home/builduser/sql-files.tar.gz -C /home/builduser/distrib/sql/ && \
    rm /home/builduser/sql-files.tar.gz

# Run the build
USER builduser
ENV WORKSPACE=/home/builduser
ENV DISABLE_MANAGER_ARM64=true
ENV PLATFORM=${TARGETPLATFORM:-linux/arm/v6}
ENV HERCULES_PACKET_VERSION=${HERCULES_PACKET_VERSION}
ENV HERCULES_SERVER_MODE=${HERCULES_SERVER_MODE}
ENV HERCULES_BUILD_OPTS=${HERCULES_BUILD_OPTS}
RUN /home/builduser/build-hercules.sh

###
# STAGE 2: BUILD IMAGE
# Here, we pick a clean minimal base image, install what dependencies
# we do need and then copy the build artifact from the build stage
# into it. Doing this as a separate stage from the build minimises
# final image size.
###

# We're picking the python:3-slim image as the base because
# unlike Alpine, this supports binary wheels which will minimise
# build time and image size for Autolycus's dependencies.
FROM --platform=${TARGETPLATFORM:-linux/arm/v7} python:3-slim AS build_image
ARG TARGETPLATFORM

# Add the MySQL APT repository and import the GPG key
RUN apt-get update && \
    apt-get install -y gnupg dirmngr && \
    rm -rf /var/lib/apt/lists/* && \
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 8C718D3B5072E1F5 && \
    echo "deb http://repo.mysql.com/apt/debian/ bullseye mysql-8.0" > /etc/apt/sources.list.d/mysql.list

ENV MYSQL_HOST=127.0.0.1
ENV MYSQL_DATABASE=ragnarok
ENV MYSQL_USERNAME=ragnarok
ENV MYSQL_PASSWORD=raganrok
ENV MYSQL_PORT=3306
ENV INTERSERVER_USER=wisp
ENV INTERSERVER_PASSWORD=wisp

# Install base system dependencies and create user.
RUN \
  apt-get update && \
  apt-get install -y \
  gcc \
  make \
  libmariadb-dev-compat \
  libmariadb-dev \
  zlib1g-dev \
  libpcre3-dev \
  mysql-client && \
  rm -rf /var/lib/apt/lists/*

RUN useradd --no-log-init -r hercules

# Install Autolycus dependencies - we're doing this as a separate step
# to optimise build cache usage. Docker will cache the image with the
# Python dependencies installed and reuse this for subsequent builds.
ENV PLATFORM=${TARGETPLATFORM}
COPY --from=build_hercules --chown=hercules /home/builduser/distrib/autolycus/requirements.txt /autolycus/
RUN pip3 install -r /autolycus/requirements.txt

# Copy the actual distribution from builder image
COPY --from=build_hercules --chown=hercules /home/builduser/distrib/ /

# Login server, Character server, Map server
EXPOSE 6900 6121 5121

USER hercules
WORKDIR /hercules
ENTRYPOINT ["/autolycus/autolycus.py", "-p", "/hercules", "setup_all", \
  "--db_hostname", "${MYSQL_HOST}", "--db_database", "${MYSQL_DATABASE}", \
  "--db_username", "${MYSQL_USERNAME}", "--db_password", "${MYSQL_PASSWORD}", \
  "--db_port", "${MYSQL_PORT}", "--is_username", "${INTERSERVER_USER}", \
  "--is_password", "${INTERSERVER_PASSWORD}"] && \
  for sql_file in /hercules/sql/*.sql; do \
    echo "Executing $sql_file"; \
    mysql -h ${MYSQL_HOST} -u ${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${MYSQL_DATABASE} < $sql_file; \
  done && \
  /autolycus/autolycus.py -p /hercules start && tail -f /hercules/log/*
