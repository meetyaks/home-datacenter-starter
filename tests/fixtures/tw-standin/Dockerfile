# STAND-IN images for roles/truewealth tests (never deployed, never pushed).
# One image per role and version, labelled like the real ones.
#   MIGRATOR  plain    the batch 1-5 migrator: summary + pending lines, exit 1
#                      exactly when something is pending
#             verdict  the batch 7+ migrator: checksums, the rollback floor,
#                      the `verdict:` last line, --adopt-legacy-checksums
#   FLOOR     the build's rollback floor constant (verdict builds)
#   MUTATE    a migration whose text this build ships EDITED (a mismatch)
FROM python@sha256:4c47124a8391cb7a9f571164147d154777cf012a4ece5f86097130d7a4478111
RUN apk add --no-cache postgresql17-client
ARG ROLE
ARG VERSION
ARG COMMIT
ARG MIGRATIONS
ARG MIGRATOR=plain
ARG FLOOR=""
ARG MUTATE=""
COPY node /usr/local/bin/node
COPY standin.py /app/standin.py
COPY migrations/ /app/all-migrations/
# /app/db/migrations, as in the real migrator image (TrueWealth Dockerfile).
RUN mkdir -p /app/db/migrations && for m in $MIGRATIONS; do cp "/app/all-migrations/$m" /app/db/migrations/; done \
 && if [ -n "$MUTATE" ]; then printf -- '-- edited after it was released\n' >> "/app/db/migrations/$MUTATE"; fi
ENV TW_STANDIN_ROLE=$ROLE TW_STANDIN_VERSION=$VERSION TW_STANDIN_MIGRATOR=$MIGRATOR TW_STANDIN_FLOOR=$FLOOR
LABEL org.opencontainers.image.revision=$COMMIT \
      org.opencontainers.image.source=https://github.com/meetyaks/truewealth \
      io.truewealth.source.tree-state=clean \
      org.opencontainers.image.title=truewealth-$ROLE \
      io.truewealth.test.standin=true
WORKDIR /app
USER 1001:1001
CMD ["node", "standin"]
