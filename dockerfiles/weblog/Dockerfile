FROM node:lts

RUN apt-get update && \
    apt-get install -y \
        git

RUN git clone http://git.maxocull.com/max/maxocull-website.git && \
    cd maxocull-website && \
    npm install

WORKDIR /maxocull-website/
CMD ["npm", "run", "serve"]
