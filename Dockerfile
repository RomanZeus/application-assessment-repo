FROM openjdk:11-jre-slim

ARG JAVA_OPTS
ENV JAVA_OPTS=$JAVA_OPTS

#working directory inside the container
WORKDIR /app

# Copy the JAR file into the container tn the /app directory
COPY target/*.war webapp.war

EXPOSE 8080

# Specify the command to run on container start
ENTRYPOINT ["exec", "java", "$JAVA_OPTS", "-jar", "webapp.war"]

