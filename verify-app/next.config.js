/** @type {import('next').NextConfig} */
module.exports = {
  // mssql / tedious open raw TCP connections - keep them out of the bundler, run on Node only
  serverExternalPackages: ["mssql", "tedious"],
  // the app shows no images - switch the image optimizer off entirely
  images: { unoptimized: true },
  poweredByHeader: false,
  // self-contained server (server.js + only the node_modules it uses) for the portable client package
  output: "standalone",
  // the package script builds into its own folder so a running `npm run dev` (.next) is not disturbed
  distDir: process.env.NEXT_DIST_DIR || ".next",
};
