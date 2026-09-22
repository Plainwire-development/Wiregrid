.PHONY: doctor bootstrap verify test load load-smoke release-check

doctor:
	./scripts/doctor.sh
bootstrap:
	./scripts/bootstrap.sh
verify:
	./scripts/verify.sh
test:
	mix test
load:
	./scripts/load.sh
load-smoke:
	USERS=100 TOPICS=10 MESSAGES=1000 ./scripts/load.sh
release-check:
	./scripts/release-check.sh
