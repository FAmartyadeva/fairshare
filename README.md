# FairShare Web

A free-to-host shared-expense web app using:

- Frontend: plain HTML/CSS/JavaScript
- Authentication + database: Supabase Free
- Code hosting: GitHub Free
- Deployment: Vercel Hobby / Free

## Features

- Email/password sign-up and login
- User profile
- Add friends by exact email
- Friend-request accept/decline flow
- Create groups
- Add accepted friends to groups
- Add equal-split expenses
- Group balances and simplified debts
- Record settlements
- Responsive web UI

## 1. Create Supabase project

1. Go to https://supabase.com and create a free project.
2. Open **SQL Editor** -> **New query**.
3. Copy all of `supabase-schema.sql`, paste it, and click **Run**.
4. Go to **Project Settings** -> **API**.
5. Copy your **Project URL** and **anon / publishable key**.
6. Open `config.js` and replace:
   - `YOUR_SUPABASE_URL`
   - `YOUR_SUPABASE_ANON_KEY`

The anon/publishable key is designed to be used client-side. Never put the Supabase `service_role` secret in this project.

### Auth setting for easiest testing

Supabase Dashboard -> Authentication -> Providers -> Email.

For immediate testing with friends, you can disable email confirmation. For a more production-like setup, keep confirmation enabled and configure the Site URL after you deploy.

## 2. Test locally

Do not double-click `index.html`; use a local HTTP server.

If Python is installed:

```bash
python -m http.server 8000
```

Then open http://localhost:8000.

## 3. Put it on GitHub

1. Create a free GitHub account/repository, for example `fairshare`.
2. In this folder run:

```bash
git init
git add .
git commit -m "Initial FairShare web app"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/fairshare.git
git push -u origin main
```

You can make the repo private on GitHub Free.

## 4. Deploy to Vercel for free

1. Sign in at https://vercel.com using GitHub.
2. Click **Add New... -> Project**.
3. Import the `fairshare` GitHub repository.
4. Framework preset: **Other**.
5. Build command: leave blank.
6. Output directory: leave blank / root.
7. Click **Deploy**.

Vercel will give you an HTTPS URL such as `fairshare-xyz.vercel.app`.

## 5. Set Supabase Auth URL

After Vercel gives you the final URL:

1. Supabase -> Authentication -> URL Configuration.
2. Set **Site URL** to the Vercel URL.
3. Add the same URL under **Redirect URLs** if you keep email confirmation enabled.

## 6. Update the app later

Edit your files, then:

```bash
git add .
git commit -m "Update FairShare"
git push
```

Vercel automatically redeploys every push to `main`.

## Free-tier caveats

This can stay at Rp0 / $0 for a small personal app as long as you remain within providers' free-tier limits. Supabase may pause an inactive free project; Vercel and Supabase free tiers also have usage limits. A custom domain is optional and domains themselves generally cost money; use the free `*.vercel.app` domain if you want 100% free.
