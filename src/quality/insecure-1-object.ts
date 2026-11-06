const express = require('express');
const bodyParser = require('body-parser');
const pug = require('pug');

const app = express();

app.use(bodyParser.urlencoded({ extended: true }));

app.post('/', (req, res) => {
  const username = req.body.username ?? '';
  const template = pug.compile(`
doctype
html
head
    title= 'Hello world'
body
    form(action='/' method='post')
        input#username.form-control(type='text' name='username' value=username)
        button.btn.btn-primary(type='submit') Submit
    p Hello #{username}`);
  const html = template({ username });
  res.send(html);
});

app.listen(3000, () => {
  console.log('Server is running on port 3000');
});
