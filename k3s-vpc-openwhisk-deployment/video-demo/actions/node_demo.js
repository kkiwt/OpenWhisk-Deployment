function main(args) {
  return {
    status: 'ok',
    group: args.GROUP || 'Group 4',
    runtime: 'nodejs',
    version: process.version,
    action: 'node-demo',
    cluster: args.CLUSTER || 'k3s-vpc-demo',
    timestamp: Date.now(),
  };
}
