.PHONY: deploy
deploy: deploy-bondy deploy-marketplace deploy-bots

.PHONY: deploy-bondy-primary
deploy-bondy-primary:
	fly deploy --config ./fly.toml --regions lhr
	fly scale vm shared-cpu-2x
	fly scale memory 2048
	fly scale count 2
	fly scale ${BONDY_SCALE} --yes --region lhr # London

.PHONY: deploy-bondy
deploy-bondy:
	fly scale count 2 --yes --region ams # Amsterdam
	fly scale count 2 --yes --region bos # Boston
	fly scale count 2 --yes --region eze # Buenos Aires
	fly scale count 2 --yes --region fra # Frankfurt
	#fly scale count 2 --yes --region gig # Rio de Janeiro
	fly scale count 2 --yes --region hkg # Hong Kong
	fly scale count 2 --yes --region iad # Virginia
	fly scale count 2 --yes --region nrt # Japan
	fly scale count 2 --yes --region waw # Poland
	fly scale count 2 --yes --region yyz # Canada

.PHONY: stop-bondy
stop-bondy:
	fly scale count 0 --yes --region lhr # London
	fly scale count 0 --yes --region ams # Amsterdam
	fly scale count 0 --yes --region bos # Boston
	fly scale count 0 --yes --region eze # Buenos Aires
	fly scale count 0 --yes --region fra # Frankfurt
	#fly scale count 0 --yes --region gig # Rio de Janeiro
	fly scale count 0 --yes --region hkg # Hong Kong
	fly scale count 0 --yes --region iad # Virginia
	fly scale count 0 --yes --region nrt # Japan
	fly scale count 0 --yes --region waw # Poland
	fly scale count 0 --yes --region yyz # Canada

.PHONY: destroy
destroy: destroy-bots destroy-marketplace destroy-bots

.PHONY: check
check:
	wick --url ws://bondy.fly.dev/ws \
	--realm com.leapsight.bondy \
	--authmethod anonymous \
	--debug \
	call bondy.cluster.info

.PHONY: nodes
nodes:
	wick --url ws://bondy.fly.dev/ws --realm com.leapsight.bondy --authmethod anonymous call bondy.cluster.info | jq '.[0].nodes | length'