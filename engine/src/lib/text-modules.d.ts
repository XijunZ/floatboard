/** Markdown files are bundled as plain text (wrangler [[rules]] Text). */
declare module "*.md" {
  const text: string;
  export default text;
}
