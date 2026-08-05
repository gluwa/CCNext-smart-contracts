import { wireReadabilityRoles } from "./env";

async function main() {
  await wireReadabilityRoles();
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
