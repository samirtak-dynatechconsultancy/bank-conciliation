/** @type {import('next').NextConfig} */
module.exports = {
  // mssql / tedious open raw TCP connections - keep them out of the bundler, run on Node only
  serverExternalPackages: ["mssql", "tedious"],
  // the app shows no images - switch the image optimizer off entirely
  images: { unoptimized: true },
  poweredByHeader: false,
};
