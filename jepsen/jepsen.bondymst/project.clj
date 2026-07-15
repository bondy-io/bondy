(defproject jepsen.bondymst "0.1.0-SNAPSHOT"
  :description "Jepsen tests for bondy_mst (3 nodes, 1 namespace, 10 tables, 16 shards)"
  :url "https://github.com/bondy-io/bondy_mst"
  :source-paths ["src/main/clojure"]
  :java-source-paths ["src/main/java"]
  :jvm-opts ["-Xmx12g"]
  :license {:name "Apache 2.0 License"
            :url "https://www.apache.org/licenses/LICENSE-2.0.html"}
  :main jepsen.bondymst
  :dependencies [[org.clojure/clojure "1.12.4"]
                 [jepsen "0.3.11"]]
  :exclusions [org.slf4j/log4j-over-slf4j
               log4j/log4j])
