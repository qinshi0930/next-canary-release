FROM node:22-alpine
ENV NODE_ENV=production

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

WORKDIR /app

COPY dist/bundle/ ./

RUN mkdir -p apps/app/.next/cache && chown nextjs:nodejs apps/app/.next/cache

USER nextjs

EXPOSE 3000
ENV PORT=3000

CMD ["node", "apps/app/server.js"]