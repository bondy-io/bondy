(defproject jepsen.bondy "0.1.0-SNAPSHOT"
  :description "Jepsen tests for the Bondy router (3-node cluster, durable RBAC users under partition and crash)"
  :url "https://github.com/bondy-io/bondy"
  :source-paths ["src/main/clojure"]
  :java-source-paths ["src/main/java"]
  :jvm-opts ["-Xmx12g"]
  :license {:name "Apache 2.0 License"
            :url "https://www.apache.org/licenses/LICENSE-2.0.html"}
  :main jepsen.bondy
  :dependencies [[org.clojure/clojure "1.12.4"]
                 [jepsen "0.3.11"]
                 ;; Admin API bodies are JSON; not a transitive dep of jepsen.
                 [cheshire "5.13.0"]]
  :exclusions [org.slf4j/log4j-over-slf4j
               log4j/log4j])
