# Kubernetes Security & Business Analytics: Turning Cluster Data into Actionable Insights

**Hands-on attendee guide** | 75 minutes | Region: **ap-southeast-2 (Sydney)** | Your own AWS account | Projected cost: about **A$0.65 per person**

## The scenario

You are investigating a suspicious incident on **ShopFast**'s shared Kubernetes cluster. Three teams use it: **payments**, **storefront** and **dev-sandbox**. You will find out what happened, why it was possible and what to fix first, then turn the data into a risk report. The slides teach the concepts; this guide is the hands-on part.

**How to use this guide:** do the steps in order. Modules 0 to 4 are essential. If you fall behind, skip Module 5. Steps marked *(optional)* can be skipped. Questions are marked **Q1, Q2...** and the answers are on the last page.

**Before you start** you need:

- An AWS account you are allowed to create resources in (a personal or sandbox account, **not production**), and a sign-in with **administrator permissions**.
- A web browser. You install nothing on your laptop; every command runs in AWS CloudShell (a terminal inside the AWS console).
- The file **`workshop.sh`**. Download the file by right clicking and selecting 'Save Link As' [here](https://github.com/DaleOrders/Kubernetes_Security_Business_Analytics_Workshop/raw/refs/heads/main/workshop.sh). Alternatively you can download a copy directly from this repo.

> **Cost warning:** the cluster costs about **A$0.33 per hour while it exists** (about A$8 a day if forgotten). Module 7 removes everything. Do not skip it.

**Typing the commands: All commands in this workshop will be run in cloudshell.**

---

## Module 0: Sign in and set up

**Step 0.1: Sign in.** Go to **https://console.aws.amazon.com/** and sign in. Use *IAM user* or your organisation's single sign-on portal (pick the account, choose the administrator role, then *Management console*). Complete any MFA prompt. You should see the AWS Console Home page.

**Step 0.2: Switch to Sydney.** Click the region name at the **top-right** of the console and choose **Asia Pacific (Sydney) `ap-southeast-2`**. Everything you build goes into the selected region, so building in the wrong one is how things get left behind and billed.

**Step 0.3: Open CloudShell.** Click the **CloudShell icon** (`[>_]`, next to the search bar at the top). Wait about 30 seconds for a prompt like `[cloudshell-user@ip-10-... ~]$`. CloudShell is a free terminal in your browser that is already signed in as you.

**Step 0.4: Check who and where you are.** This confirms your account and region.

```bash
aws sts get-caller-identity
aws ec2 describe-availability-zones --query "AvailabilityZones[0].RegionName" --output text
```

The first shows your account number and user. The second must print `ap-southeast-2`. If not, close CloudShell, repeat Step 0.2 and reopen it.

**Step 0.5: Upload the workshop file.** Save `workshop.sh` on your computer first. Then upload it to CloudShell:

1. In the CloudShell window, click **Actions** (top right of the terminal).
2. Choose **Upload file**.
3. Click **Select file**, choose `workshop.sh`, then click **Upload**.
4. Wait for the message saying the upload is complete.

Check that the file arrived. You should see `workshop.sh` in the list:

```bash
ls ~
```

Move it into its own folder and make it runnable:

```bash
mkdir -p ~/ws && mv ~/workshop.sh ~/ws/ && cd ~/ws && chmod +x workshop.sh
```

Check that you are in the right folder:

```bash
pwd
```

It should print `/home/cloudshell-user/ws`. If you get `No such file or directory`, the upload did not finish: repeat steps 1 to 4. Run every later command from this `ws` folder. If you open a new CloudShell tab, type `cd ~/ws` first.

**Step 0.6: Unpack the files and install the tools.** This creates the files used in the workshop and installs two tools: **eksctl** (builds the cluster) and **helm** (installs software into it).

```bash
./workshop.sh unpack
./workshop.sh tools
```

You should see three image names, then `Created: app.yaml fixed.yaml risk_report.py`, then the tools installing, ending with `Tools installed. Now run: source ~/.bashrc`.

**Step 0.7: Load the tools and check them.** This makes the new tools available in your terminal.

```bash
source ~/.bashrc
eksctl version
```

`eksctl version` should print a version number, for example `0.231.0` (yours may be newer).

**Step 0.8: Start building the cluster.** This takes about 15 minutes and runs in the background.

```bash
./workshop.sh create
tail -f create-cluster.log
```

The first command should print your identity and `Cluster creation started`. The second shows the build log; lines such as `creating CloudFormation stack "eksctl-sec-analytics-ws-cluster"` mean it is working. If you see `No such file or directory`, check you typed the leading `./` and that your prompt shows `ws` (if not, run `cd ~/ws`).

<img width="3454" height="588" alt="Screenshot 2026-10-12 at 1 44 57 am" src="https://github.com/user-attachments/assets/adaf66bc-337a-4bf2-9210-7d9178dbc11d" />


Press **Ctrl+C** to stop watching the log. The build keeps going. **CloudShell closes after 20 to 30 minutes with no keyboard activity**, so press a key every few minutes while you wait.

**Checkpoint 0:** the log is growing with no red errors.

---

## Module 1: While the cluster builds

Open a new terminal by clicking the plus button and selecting ap-southeast-2.

<img width="3454" height="898" alt="Screenshot 2026-10-12 at 1 50 04 am" src="https://github.com/user-attachments/assets/fac47e60-58a8-4b8a-b34e-89899ea4ad0c" />


> **While the cluster builds:** do **Steps 1.1, 1.2 and 1.3** straight away, and **Step 1.4** after about 10 minutes. Do not start Module 2 until the build has finished.

**Step 1.1: Watch AWS build it.** In the console search bar open **CloudFormation**. Click the stack **`eksctl-sec-analytics-ws-cluster`**, open the **Events** tab and refresh a few times. You will see the network, an IAM role and then the cluster appear.

**Step 1.2: Spot the Errors.** ShopFast's engineers wrote the apps you are about to deploy and made some mistakes. This command opens the file so you can read it and find them.

```bash
less app.yaml
```

Use the **arrow keys or Page Down** to scroll. **Press `q` to quit** and get your prompt back. There are 10 mistakes/security risks in the file

Hints: old image versions, containers that are privileged or run as root, access to the underlying server, missing CPU and memory limits, roles that allow too much, and how passwords reach the app.

> **Q1.** List every problem you can find in `app.yaml`. Score 1 point for each (out of 10).

**Step 1.3: Find the business context.** This prints the first 45 lines of `app.yaml` (press `q` first if you are still in the previous file).

```bash
head -n 45 app.yaml
```

Find the `tier:` label and the `revenue-aud-per-day` annotation on each namespace. Later, the risk report uses them to rank the teams.

> **Q2.** Why do the `tier` label and the revenue annotation matter?

**Checkpoint 1:** you have found the errors in `app.yaml` and the cluster build is under way.

---

## Module 2: Deploy ShopFast (after the cluster has finished building)

**Step 2.1: Connect.** Check the build has finished. The last line of the log should say `EKS cluster "sec-analytics-ws" in "ap-southeast-2" region is ready`:

```bash
tail -n 5 create-cluster.log
```

Then connect to the cluster:

```bash
./workshop.sh connect
```

You should see **two nodes with STATUS `Ready`**. If it says the cluster is not ready, wait a minute and try again.

<img width="1542" height="150" alt="image" src="https://github.com/user-attachments/assets/97a2e7a1-6253-49f5-9827-1b4ccc3a3c23" />


**Step 2.2: Deploy the three teams' apps.** This starts the apps from `app.yaml` in the cluster.

```bash
kubectl apply -f app.yaml
```

You will see lines ending in `created`. You will also see warnings such as `Warning: would violate PodSecurity "baseline:latest": privileged ...`. These come from Kubernetes' built-in safety check, which warns about apps that break basic security rules. We set it to warn only, so the apps still start.

> **Q3.** Why start in warn mode instead of blocking?

**Step 2.3: Wait for the apps to start.** The first command waits until they are ready; the second lists them.

```bash
kubectl wait --for=condition=available deployment --all -A --timeout=240s
kubectl get pods -A
```

You should see pods in `payments`, `storefront` and `dev-sandbox` with STATUS `Running`.

<img width="1542" height="240" alt="image" src="https://github.com/user-attachments/assets/ce67c1cb-302a-49cd-b3a1-eeeb23946fdb" />


**Step 2.4: Take a baseline.** This shows how busy each server is right now.

```bash
kubectl top nodes
```

If it says metrics are not available, wait a minute and try again. Write down the CPU% of each node: ______ and ______ (expect low numbers).

**Step 2.5: Install the scanner.** This installs **Trivy**, a security scanner that checks everything running in the cluster. It takes 1 to 2 minutes.

```bash
./workshop.sh trivy
kubectl get jobs -n trivy-system
```

You should see `Trivy Operator is running`, then a list of scan jobs. The scans run in the background and take a few minutes, so carry on.

<img width="1542" height="67" alt="image" src="https://github.com/user-attachments/assets/4f6802b0-ffb0-41a3-8e1a-c2044269dfe1" />


**Checkpoint 2:** the apps are `Running` and Trivy is installed.

---

## Module 3: The incident

**Step 3.1: Start the incident.** This plays an intruder who has stolen an access token from `dev-sandbox`. I

```bash
./workshop.sh incident
```

Read the green lines as they appear. You should see:

- `yes` for "can this token list secrets everywhere?"
- Tables of secrets from `payments` and `storefront` (**allowed**).
- Three `Forbidden` errors (**denied**): listing the servers, getting into the `payments-api` app, and listing pods as `system:anonymous`.
- `deployment.apps/cache-warmer created`.

<img width="1542" height="325" alt="image" src="https://github.com/user-attachments/assets/de7477c4-9d77-47f1-b439-9eb084bd16c9" />


**Step 3.2: Lens 1, Metrics.** Metrics show how busy things are. Wait about 90 seconds, then run these three commands: the busiest pods, the busiest servers, and recent cluster events.

```bash
kubectl top pods -A --sort-by=cpu | head -n 6
kubectl top nodes
kubectl get events -A --sort-by=.lastTimestamp | tail -n 8
```

`cache-warmer` should be at or near the top for CPU, and one server should be busier than your baseline.

> **Q4.** Can the metrics tell you who created `cache-warmer` or why it was allowed?

**Step 3.3: Lens 2, Audit logs.** The audit log records every request made to the cluster: who made it, what they asked for, and whether it was allowed.

*Part A: the console.*

1. In the console search bar open **CloudWatch**, then in the left menu expand **Logs** and choose **Log Management**.
2. Select the log group **`/aws/eks/sec-analytics-ws/cluster`**.
3. In the top right-hand corner, click the **Logs Insights** button.
4. If you are asked to choose a query language, choose **Logs Insights QL**.
5. Set the time range to **1h**.
6. Replace the text in the query box with this query and click **Run query**:

```
fields impersonatedUser.username as actor, objectRef.namespace as ns, verb, responseStatus.code as code
| filter objectRef.resource = "secrets" and ispresent(impersonatedUser.username) and verb in ["get","list"]
| stats count(*) as reads by actor, ns, verb, code
| sort reads desc
```

This finds every time someone read secrets in the cluster we created. You should see **two results**, one for each namespace the intruder read. If you only see the number **2**, click it to open them. For each result, note:

- `actor`: who did it (the stolen `dev-sandbox` identity).
- `ns`: which namespace.
- `verb`: the action (`list`).
- `code`: the result. **200 means allowed**, 403 means denied.

If you cannot see `code`, or the screen does not match these steps, run `./workshop.sh query secrets` in CloudShell instead. It runs the same query and shows every column. If there are no results, the logs take 1 to 3 minutes to arrive: wait and run it again.

> **Q5.** Which identity read secrets, in which namespaces, and did it succeed?

*Part B: In cloudshell.* Run these one at a time.

```bash
./workshop.sh query forbidden
```

This shows requests that were **refused**. Look for three rows with code **403**: `system:anonymous` **list pods**, `dev-sandbox:default` **list nodes**, and `dev-sandbox:default` **get deployments**. These are the intruder's blocked attempts. Ignore the other rows: the 404 just means "not found", and the 429 rows are AWS's own background activity.

<img width="1697" height="420" alt="image" src="https://github.com/user-attachments/assets/5bdfa2d1-69f5-4fa6-9e1b-7a05badc32a0" />


```bash
./workshop.sh query changes
```

This shows what was **created or changed**, and by whom. Find the row where `dev-sandbox:default` **creates** the **deployments** object named **cache-warmer** in **dev-sandbox**. That tells you who made it and when. Ignore the `selfsubjectaccessreviews` row (a harmless permission check). If columns are cut off, make the CloudShell window wider.

```bash
./workshop.sh query psa
```

This counts the Pod Security warnings each namespace triggered. Each namespace shows 2 for deployments, replicasets and pods, because none of the apps use safe security settings. This is background information, not part of the incident.

**Step 3.4: Lens 3, Configuration.** The audit log showed what the token did. These commands show why it was allowed. Run them one at a time.

```bash
kubectl auth can-i get secrets -n payments --as=system:serviceaccount:dev-sandbox:default
```

This asks "can the dev-sandbox token read secrets in `payments`?". It prints **`yes`**, so something is giving it that permission.

```bash
kubectl get clusterrolebinding dev-secrets-reader-binding -o wide
```

This shows the permission that was given, and to whom. In the one row, **ROLE** shows `ClusterRole/dev-secrets-reader` and **SERVICEACCOUNTS** shows `dev-sandbox/default`, the identity the intruder stole.

```bash
kubectl describe clusterrole dev-secrets-reader
```

This shows what that role allows. Under `PolicyRule`, **Resources** is `secrets` and **Verbs** is `[get list]`. It is a cluster-wide role, so it lets `dev-sandbox` read secrets in **every namespace**.

```bash
kubectl get role,rolebinding -n dev-sandbox
```

This shows a second problem: a Role named `dev-wildcard` that lets the same identity do anything inside `dev-sandbox`.

> **Q6.** Complete the timeline. (a) **Metrics** (Step 3.2) showed the app named ______ using a lot of CPU. (b) The **audit log** (Step 3.3) showed the token ______ (two things it did successfully). (c) The **configuration** (this step) allowed it because of a ______ named ______ that lets the `dev-sandbox` identity read ______ in every namespace.

**Checkpoint 3:** you can explain the incident in three sentences.

---

## Module 4: Read the scan findings

By now Trivy should have finished most of its scans.

**Step 4.1: Vulnerabilities in images.** Trivy opens each container image, lists the software inside it and checks it against a public list of **known vulnerabilities** (security weaknesses). This command shows the results.

```bash
kubectl get vulnerabilityreports -A -o wide
```

You should see **one row per app**. **The counts are not attacks.** They are the number of known weaknesses in the software inside the image. Nobody has exploited them; someone *could*. How to read a row:

| Column | Meaning |
|---|---|
| `NAMESPACE`, `NAME` | The team and the app that was scanned |
| `REPOSITORY`, `TAG` | The image and version it runs |
| `AGE` | How long ago the scan ran |
| `CRITICAL` | Rated 9.0 to 10 out of 10: the most dangerous |
| `HIGH` | Rated 7.0 to 8.9: serious |
| `MEDIUM` | Rated 4.0 to 6.9: moderate |
| `LOW` | Rated 0.1 to 3.9: minor |
| `UNKNOWN` | No rating has been published yet |

The numbers change daily as new weaknesses are published, so yours will differ from your neighbour's. If an app is missing from the list, its scan has not finished: wait a minute and run the command again. If two rows show the same numbers, those apps use the same image.

> **Q7.** Which image and tag has the **fewest** vulnerabilities? Does that mean the app using it is automatically secure? Give a reason.

**Step 4.2: Unsafe configuration.** This shows which apps are set up unsafely (for example running as root or privileged), as opposed to which software inside them has known weaknesses.

```bash
kubectl get configauditreports -A -o wide
```

Each row is one app, and the columns count the checks it failed. Look for `debug-tool` in `dev-sandbox`: it should show HIGH (or higher) failures because it runs privileged.

**Step 4.3: Excessive permissions.** This shows who has more permission than they need.

```bash
kubectl get rbacassessmentreports -A -o wide
```

Look for the `dev-wildcard` Role in `dev-sandbox`: it should show a CRITICAL or HIGH count because it allows every action on everything.

> **Q8.** Trivy flagged the wildcard Role, but which data source showed that `dev-sandbox` actually read `payments` secrets? Why do you need both?

**Checkpoint 4:** you can say what each Trivy report shows: weaknesses in the software (4.1), unsafe setup (4.2) and too much permission (4.3). Check your Q1 score against the answers.

---

## Module 5: From data to decisions

**Step 5.1: Generate the risk report.** This turns the Trivy results into a risk report.

```bash
python3 risk_report.py --label before
```

It prints two tables. **Table 1** gives each namespace a risk score (more serious findings and more important teams contribute more to the overall score). **Table 2**, the fix-first list, shows which fixes would remove the most risk. Your numbers will differ from your neighbour's, so focus on which items rank highest.

<img width="1697" height="340" alt="image" src="https://github.com/user-attachments/assets/6097dce8-6d0a-4403-9aff-db82068b5431" />


> **Q9.** (a) Which namespace carries the most risk? (b) Why does it rank there? (c) What is #1 on the fix-first list? (d) How many apps does that one fix improve?

**Step 5.2 *(optional)*: Add what the audit log in cloudwatch taught us.** The report treated `dev-sandbox` as low importance, but the audit log from cloudwatcch insights showed its token could read `payments` secrets which makes it considerably more consequential. This command re-runs the report treating `dev-sandbox` as a **critical** source of vulnerability. See how this changes the ranking.

```bash
python3 risk_report.py --label escalated --escalate dev-sandbox=critical
```

> **Q10.** What changed for `dev-sandbox` compared with Step 5.1, and why is it right to treat it as critical?

**Step 5.3: Write the message for the business.** Use your results to fill in this message.

> **Q11.** *"Our payments platform carries ___% of cluster risk, mostly from ______. Fixing ______ would remove ___ risk points across ___ teams."*

> **Q12 *(senior engineers, optional)*.** This risk score is simple. What two extra things would you add to make it more realistic?

**Checkpoint 5:** you have a ranked list and a one-line message for the business.

---

## Module 6: Fix it and prove it

**Step 6.1: Apply the fixes.** This removes the problems and replaces the old apps with safer versions.

```bash
./workshop.sh fix
```

It removes `cache-warmer` and `debug-tool`, deletes the two overly-broad permissions, and replaces the three old `nginx` apps with safer ones from `fixed.yaml`. You should see `deleted` lines and `deployment.apps/... configured`.

**Step 6.2: Wait for the re-scan.** Trivy re-scans the changed apps, which takes 2 to 3 minutes. While you wait, check the apps, then read the safer version (press `q` to quit):

```bash
kubectl get pods -A
less fixed.yaml
```

**Step 6.3: Prove the improvement.** This runs the risk report again.

```bash
python3 risk_report.py --label after
```

Look for the section **`=== BEFORE vs AFTER ===`** at the bottom to see the reduction in risk: it lists each namespace's risk before and after, then the total reduction as a percentage. If the risk has not dropped, the re-scan is still running: wait a minute and run it again. Using both cloudwatch log insights and trivy, we have been able to identify and reduce vulnerability by targeting the most at-risk workloads.

**Checkpoint 6:** the risk went down because you fixed the highest-ranked problems.

---

## Module 7: Clean up

**Do not skip this module.** It deletes everything you built so you are not billed afterwards.

**Step 7.1: Delete everything.** Make sure your prompt shows `ws` (if not, run `cd ~/ws`), then type the command exactly, **including the `./` at the start**:

```bash
./workshop.sh cleanup
```

If you see `bash: /workshop.sh: No such file or directory`, the leading dot is missing: type `./workshop.sh cleanup`.

This takes about **10 minutes**. It deletes the cluster, servers, network and IAM roles, and the audit log group, then checks that everything is gone. **Keep the CloudShell tab open until it finishes.**

**Step 7.2: Confirm it is gone.** At the end you should see `[ OK ] ... none left` for each item, then `ALL CLEAN`. You can run the check again at any time:

```bash
./workshop.sh verify
```

**Step 7.3: Check the console.** This is the final check. With Sydney selected, confirm each of these is empty: **EKS** clusters (no `sec-analytics-ws`), **CloudFormation** stacks (none starting `eksctl-sec-analytics-ws`), **EC2** instances (nothing running), **CloudWatch** log groups (no `/aws/eks/sec-analytics-ws/cluster`) and **VPC** (none named `eksctl-sec-analytics-ws...`).

<img width="1697" height="177" alt="image" src="https://github.com/user-attachments/assets/ef98e5ec-0881-4fa4-9d97-c16bb01f5754" />


---

## Projected cost

Approximate Australian dollars for Sydney, for about **1.75 hours** of cluster life. AWS publishes prices in US dollars; these are converted at about US$1 = A$1.43 (October 2026) and exclude GST. Your invoice currency and exchange rate may differ. Check the [AWS Pricing Calculator](https://calculator.aws/) for current rates.

| Item | Cost |
|---|---|
| EKS control plane (A$0.14 per hour) | A$0.26 |
| 2 x `t3.medium` servers (about A$0.076 per hour each) | A$0.27 |
| 2 x 20 GB gp3 disks | A$0.01 |
| 2 public IPv4 addresses (about A$0.007 per hour each) | A$0.03 |
| CloudWatch Logs (audit log, under 100 MB) | under A$0.07 |
| Burst CPU credits from the incident (worst case) | up to A$0.04 |
| NAT gateway (turned off in the config), CloudShell | A$0.00 |
| **Total per attendee** | **about A$0.65 (budget up to A$1.50)** |

Left running, the cluster costs about A$0.33 per hour (about A$8 a day). Standard managed servers were chosen over EKS Auto Mode because Auto Mode is no faster to build here, adds a per-instance fee and would likely need a NAT gateway.

---

## Answers

**Q1.** These are the 10 errors in `app.yaml` (1 point each):

| What is wrong | Why it matters |
|---|---|
| Old `nginx` image (payments-api, storefront-web, storefront-promo) | Many known vulnerabilities. One image used by three apps in two teams |
| Old `redis` image (payments-cache) | No longer gets security fixes |
| `latest` tag on `debug-tool` | You can't tell which version is running |
| No `securityContext`, so containers run as root | More damage if one is broken into |
| No CPU or memory limits | One busy app can starve the server |
| `debug-tool` is privileged | Almost full access to the server |
| `hostPath` mount of `/var/log` in storefront-web | The app can read the server's files |
| Wildcard Role `dev-wildcard` | It can do anything inside dev-sandbox |
| ClusterRoleBinding that lets dev-sandbox read secrets in every namespace | The cause of the incident |
| Password passed to `payments-api` as an environment variable | It can leak into logs or be read by anyone who opens a shell in the app |

**Q2.** Without them every finding looks equally important. The script uses them to rank a flaw in `payments` above the same flaw in `dev-sandbox`.

**Q3.** To see what would break before you start blocking. Warn first, enforce later.

**Q4.** No. Metrics show something is wrong, but not who did it or why it was allowed.

**Q5.** The actor is `system:serviceaccount:dev-sandbox:default`. It listed secrets in `payments` and `storefront`, and both calls succeeded (code 200).

**Q6.** (a) `cache-warmer`. (b) The token read secrets in `payments` and `storefront`, and created the `cache-warmer` deployment. (c) A ClusterRoleBinding named `dev-secrets-reader-binding`, which lets `dev-sandbox` read secrets in every namespace.

**Q7.** `busybox:latest` (often zero vulnerabilities). No, it is not automatically secure. Trivy only checks for known vulnerabilities in the software. It does not check how the app is configured, and `debug-tool` is privileged with very broad permissions.

**Q8.** The audit log we saw in cloudwatch log insights. Trivy shows what could happen (bad settings); the audit log shows what did happen (who did what). You need both.

**Q9.** (a) `payments`. (b) It is in the critical tier, so its score is multiplied by 3. (c) The old `nginx` image. (d) Three apps (in two teams). For example, one run showed `payments` at 906 points (53% of the total) and the `nginx` image at 1,049 points. Your numbers will differ slightly, but the order should be the same.

**Q10.** Its score triples (tier x1 becomes x3), for example from 80 to about 240. It is right because the audit log showed `dev-sandbox` can reach `payments` secrets, so it is as sensitive as `payments`.

**Q11.** Example only: "Our payments platform carries about 53% of cluster risk, mostly from an old nginx image. Fixing that image would remove about 1,050 risk points across 2 teams." Your numbers will differ.

**Q12.** Examples: whether the app is on the internet, how sensitive its data is, whether a fix exists, how likely the flaw is to be exploited, and how much effort the fix takes.
