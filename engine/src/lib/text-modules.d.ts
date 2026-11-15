/** Markdown files and the phone app's scripts (*.client.js) are bundled as plain text (wrangler [[rules]] Text). */
declare module "*.md" {
  const text: string;
  export default text;
}
declare module "*.client.js" {
  const text: string;
  export default text;
}
