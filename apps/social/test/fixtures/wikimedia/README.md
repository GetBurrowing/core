# Wikimedia daily pageviews fixture

`top-en-2026-11-13.json` is an anonymized response retrieved on
2026-11-15 from
`https://wikimedia.org/api/rest_v1/metrics/pageviews/top/en.wikipedia/all-access/2026/11/13`.
The one read used an identifying `BurrowResearchBot/0.1` User-Agent with the
public project URL as the contact. It retains the real envelope, 1,000 ranks,
view counts and tie pattern. Article names were replaced with numbered synthetic
names, retaining recognized namespace prefixes and `Main_Page`, to avoid
embedding unrelated names in the test tree. It exercises the real response
shape, not the original titles.

Wikimedia describes the Analytics API data as CC0 and requires an identifying
client, adherence to its terms and rate limits:
https://doc.wikimedia.org/generated-data-platform/aqs/analytics-api/documentation/access-policy.html
No page content or images are included in this fixture.
