# STAND-IN images for roles/truewealth tests (never deployed, never pushed).
# One image per role and version, labelled like the real ones.
FROM python@sha256:4c47124a8391cb7a9f571164147d154777cf012a4ece5f86097130d7a4478111
RUN apk add --no-cache postgresql17-client
ARG ROLE
ARG VERSION
ARG COMMIT
ARG MIGRATIONS
COPY node /usr/local/bin/node
COPY standin.py /app/standin.py
COPY migrations/ /app/all-migrations/
RUN mkdir -p /app/dist/ops/migrations && for m in $MIGRATIONS; do cp "/app/all-migrations/$m" /app/dist/ops/migrations/; done
ENV TW_STANDIN_ROLE=$ROLE TW_STANDIN_VERSION=$VERSION
LABEL org.opencontainers.image.revision=$COMMIT \
      org.opencontainers.image.source=https://github.com/meetyaks/truewealth \
      io.truewealth.source.tree-state=clean \
      org.opencontainers.image.title=truewealth-$ROLE \
      io.truewealth.test.standin=true
WORKDIR /app
USER 1001:1001
CMD ["node", "standin"]
