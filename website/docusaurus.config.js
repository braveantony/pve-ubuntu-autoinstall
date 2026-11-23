// Documentation site. The pages are the Markdown files in ../docs, the same
// files GitHub renders, so there is one copy of every document. The home page
// is generated from ../README.md on each start/build.
const fs = require('fs');
const path = require('path');
const { themes } = require('prism-react-renderer');

const repoUrl = 'https://github.com/braveantony/pve-ubuntu-autoinstall';

// README.md -> src/pages/index.md, with links rewritten for the site.
const readme = fs
  .readFileSync(path.join(__dirname, '..', 'README.md'), 'utf8')
  .replace(/\]\(docs\/architecture\//g, '](../../../docs/architecture/')
  .replace(/\]\(docs\/([a-z-]+)\.md(#[^)]*)?\)/g, '](/docs/$1$2)')
  .replace(/\]\(LICENSE\)/g, `](${repoUrl}/blob/master/LICENSE)`);
fs.mkdirSync(path.join(__dirname, 'src', 'pages'), { recursive: true });
fs.writeFileSync(
  path.join(__dirname, 'src', 'pages', 'index.md'),
  `---\ntitle: pve-ubuntu-autoinstall\n---\n\n${readme}`,
);

/** @type {import('@docusaurus/types').Config} */
module.exports = {
  title: 'pve-ubuntu-autoinstall',
  tagline: '在 Proxmox VE 上用設定檔建立 Ubuntu Server 26.04 的範本與 VM',
  url: 'https://braveantony.github.io',
  baseUrl: '/pve-ubuntu-autoinstall/',
  organizationName: 'braveantony',
  projectName: 'pve-ubuntu-autoinstall',
  trailingSlash: false,
  onBrokenLinks: 'throw',
  onBrokenAnchors: 'throw',

  i18n: { defaultLocale: 'zh-Hant', locales: ['zh-Hant'] },

  // The documents are plain GitHub Markdown, not MDX.
  markdown: {
    format: 'detect',
    hooks: { onBrokenMarkdownLinks: 'throw', onBrokenMarkdownImages: 'throw' },
  },

  presets: [
    [
      'classic',
      {
        docs: {
          path: '../docs',
          routeBasePath: 'docs',
          sidebarPath: './sidebars.js',
          editUrl: `${repoUrl}/edit/master/docs/`,
          include: ['*.md'],
        },
        blog: false,
        theme: { customCss: './src/css/custom.css' },
      },
    ],
  ],

  themeConfig: {
    navbar: {
      title: 'pve-ubuntu-autoinstall',
      items: [
        { to: '/docs/getting-started', label: '建置手冊', position: 'left' },
        { to: '/docs/how-it-works', label: '運作原理', position: 'left' },
        { to: '/docs/operations', label: '日常操作', position: 'left' },
        { href: `${repoUrl}/releases`, label: 'Releases', position: 'right' },
        { href: repoUrl, label: 'GitHub', position: 'right' },
      ],
    },
    footer: {
      style: 'dark',
      copyright: `Copyright © ${new Date().getFullYear()} braveantony. MIT License.`,
    },
    prism: {
      theme: themes.github,
      darkTheme: themes.dracula,
      additionalLanguages: ['bash', 'diff', 'hcl', 'json', 'yaml'],
    },
    tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 4 },
  },
};
